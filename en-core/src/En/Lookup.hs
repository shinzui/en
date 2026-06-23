{-# LANGUAGE NoFieldSelectors #-}

-- | Reverse expansion: list the objects a subject can reach with a permission.
module En.Lookup (
    LookupCursor (..),
    LookupLimit (..),
    LookupRequest (..),
    LookupObject (..),
    LookupState (..),
    LookupPage (..),
    lookup,
) where

import Prelude hiding (lookup)

import Data.List (sortOn)
import Data.Map.Strict qualified as Map
import Data.Maybe (mapMaybe)
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text qualified as Text

import En.Check (CaveatObligation (..), CheckDecision (..), check)
import En.Effect.ConsistencyStore (ConsistencyStore (..), ResolvedConsistency (..))
import En.Effect.TupleStore (PageState (..), StoreCursor, TuplePage (..), TupleRow (..), TupleStore (..), UsersetQuery (..))
import En.Error (EnError (..))
import En.Reachability (ReachabilityGraph (..), RelationRef (..))
import En.Revision (Consistency, Revision)
import En.Schema (AllowedSubject (..), CaveatName (..), ObjectType (..), Relation (..), RelationName (..), Rewrite (..))
import En.Tuple (
    CaveatContext (..),
    CaveatPayload (..),
    CaveatValue (..),
    ObjectRef (..),
    Subject (..),
    Tuple (..),
    TupleCaveat (..),
 )

newtype LookupCursor = LookupCursor
    { cursorEncoding :: Text
    }
    deriving stock (Eq, Ord, Show)

newtype LookupLimit = LookupLimit
    { unLookupLimit :: Int
    }
    deriving stock (Eq, Ord, Show)

data LookupRequest = LookupRequest
    { subject :: !Subject
    , permission :: !RelationName
    , objectType :: !ObjectType
    , context :: !CaveatContext
    , limit :: !LookupLimit
    , cursor :: !(Maybe LookupCursor)
    }
    deriving stock (Eq, Show)

data LookupObject = LookupObject
    { object :: !ObjectRef
    , decision :: !CheckDecision
    }
    deriving stock (Eq, Show)

data LookupState
    = LookupExhausted
    | LookupHasMore !LookupCursor
    | LookupTruncated !LookupCursor
    deriving stock (Eq, Ord, Show)

data LookupPage = LookupPage
    { objects :: ![LookupObject]
    , state :: !LookupState
    }
    deriving stock (Eq, Show)

{- | List the objects of @objectType@ on which @subject@ has @permission@:
reverse expansion (subject → resource) plus reach-then-check for conditional
entrypoints (intersection / exclusion / caveats), streamed and cursorable.
This is the read-filter primitive (e.g. kawa filtering the activity stream).
-}
lookup ::
    (Monad m) =>
    ConsistencyStore m ->
    TupleStore m ->
    ReachabilityGraph ->
    Consistency ->
    LookupRequest ->
    m (Either EnError LookupPage)
lookup consistencyStore tupleStore graph consistency request = do
    resolved <- consistencyStore.resolveConsistency consistency
    case resolved of
        Left err -> pure (Left err)
        Right ResolvedConsistency{revision} ->
            runLookup consistencyStore tupleStore graph revision consistency request

runLookup ::
    (Monad m) =>
    ConsistencyStore m ->
    TupleStore m ->
    ReachabilityGraph ->
    Revision ->
    Consistency ->
    LookupRequest ->
    m (Either EnError LookupPage)
runLookup consistencyStore tupleStore graph revision consistency request = do
    candidates <- evalRelation consistencyStore tupleStore graph request.context revision consistency request.subject request.objectType request.permission initialState
    pure (pageLookup request.limit request.cursor <$> candidates)

data EvalState = EvalState
    { depth :: !Int
    , visited :: ![Subproblem]
    , skipRecursive :: !(Maybe RecursiveStep)
    }

data Subproblem = Subproblem
    { subject :: !Subject
    , objectType :: !ObjectType
    , relation :: !RelationName
    }
    deriving stock (Eq, Show)

data RecursiveStep = RecursiveStep
    { tuplesetRelation :: !RelationName
    , computedRelation :: !RelationName
    }
    deriving stock (Eq, Show)

initialState :: EvalState
initialState =
    EvalState{depth = 0, visited = [], skipRecursive = Nothing}

maxDepth :: Int
maxDepth = 25

pageLimit :: Int
pageLimit = 1000

resultCap :: Int
resultCap = 1000

evalRelation ::
    (Monad m) =>
    ConsistencyStore m ->
    TupleStore m ->
    ReachabilityGraph ->
    CaveatContext ->
    Revision ->
    Consistency ->
    Subject ->
    ObjectType ->
    RelationName ->
    EvalState ->
    m (Either EnError [LookupObject])
evalRelation consistencyStore tupleStore graph context revision consistency subject objectType relation state
    | state.depth >= maxDepth =
        pure (Left ResolutionLimitExceeded)
    | subproblem `elem` state.visited && state.skipRecursive == Nothing =
        pure (Right [])
    | otherwise =
        case Map.lookup ref graph.relations of
            Nothing ->
                pure (Left (UnknownRelation (renderRef ref)))
            Just schemaRelation ->
                evalRewrite
                    consistencyStore
                    tupleStore
                    graph
                    context
                    revision
                    consistency
                    subject
                    objectType
                    relation
                    schemaRelation.rewrite
                    EvalState{depth = state.depth + 1, visited = subproblem : state.visited, skipRecursive = state.skipRecursive}
  where
    ref = RelationRef{objectType, relation}
    subproblem = Subproblem{subject, objectType, relation}

evalRewrite ::
    (Monad m) =>
    ConsistencyStore m ->
    TupleStore m ->
    ReachabilityGraph ->
    CaveatContext ->
    Revision ->
    Consistency ->
    Subject ->
    ObjectType ->
    RelationName ->
    Rewrite ->
    EvalState ->
    m (Either EnError [LookupObject])
evalRewrite consistencyStore tupleStore graph context revision consistency subject objectType currentRelation rewrite state =
    case rewrite of
        This ->
            evalThis consistencyStore tupleStore graph context revision consistency subject objectType currentRelation state
        ComputedUserset relation ->
            evalRelation consistencyStore tupleStore graph context revision consistency subject objectType relation state
        TupleToUserset tuplesetRelation computedRelation ->
            evalTupleToUserset consistencyStore tupleStore graph context revision consistency subject objectType currentRelation tuplesetRelation computedRelation state
        Union rewrites -> do
            results <- traverse (\current -> evalRewrite consistencyStore tupleStore graph context revision consistency subject objectType currentRelation current state) rewrites
            pure (mergeLookupObjects . concat <$> sequence results)
        Intersection rewrites ->
            confirmCandidates consistencyStore tupleStore graph context consistency subject currentRelation
                =<< unionBranches rewrites
        Exclusion base _subtractRewrite ->
            confirmCandidates consistencyStore tupleStore graph context consistency subject currentRelation
                =<< evalRewrite consistencyStore tupleStore graph context revision consistency subject objectType currentRelation base state
        Caveated caveat rewriteInner -> do
            inner <- evalRewrite consistencyStore tupleStore graph context revision consistency subject objectType currentRelation rewriteInner state
            pure (applyGateToObjects (evaluateRewriteCaveat caveat context) <$> inner)
  where
    unionBranches rewrites = do
        results <- traverse (\current -> evalRewrite consistencyStore tupleStore graph context revision consistency subject objectType currentRelation current state) rewrites
        pure (mergeLookupObjects . concat <$> sequence results)

evalThis ::
    (Monad m) =>
    ConsistencyStore m ->
    TupleStore m ->
    ReachabilityGraph ->
    CaveatContext ->
    Revision ->
    Consistency ->
    Subject ->
    ObjectType ->
    RelationName ->
    EvalState ->
    m (Either EnError [LookupObject])
evalThis consistencyStore tupleStore graph context revision consistency subject objectType relation state = do
    direct <- readRowsForSubjects tupleStore revision objectType relation [subject]
    case direct of
        Left err -> pure (Left err)
        Right directRows -> do
            usersetRows <- rowsForAllowedUsersets
            let directObjects = mapMaybe rowLookupObject directRows
            pure (mergeLookupObjects . (directObjects <>) <$> usersetRows)
  where
    rowsForAllowedUsersets = do
        case lookupRelation graph objectType relation of
            Left err -> pure (Left err)
            Right relationDefinition -> do
                collected <-
                    traverse
                        ( \allowed ->
                            case allowed.relation of
                                Nothing -> pure (Right [])
                                Just subjectRelation -> do
                                    subjectObjects <- evalRelation consistencyStore tupleStore graph context revision consistency subject allowed.objectType subjectRelation state
                                    case subjectObjects of
                                        Left err -> pure (Left err)
                                        Right objects -> do
                                            let subjectSets = [SubjectSet object subjectRelation | LookupObject{object} <- objects]
                                            rows <- readRowsForSubjects tupleStore revision objectType relation subjectSets
                                            pure (mapMaybe rowLookupObject <$> rows)
                        )
                        (Set.toAscList relationDefinition.allowedSubjects)
                pure (mergeLookupObjects . concat <$> sequence collected)
    rowLookupObject TupleRow{tuple} =
        LookupObject tuple.object <$> includeDecision context tuple.caveat Allowed

evalTupleToUserset ::
    (Monad m) =>
    ConsistencyStore m ->
    TupleStore m ->
    ReachabilityGraph ->
    CaveatContext ->
    Revision ->
    Consistency ->
    Subject ->
    ObjectType ->
    RelationName ->
    RelationName ->
    RelationName ->
    EvalState ->
    m (Either EnError [LookupObject])
evalTupleToUserset consistencyStore tupleStore graph context revision consistency subject objectType currentRelation tuplesetRelation computedRelation state
    | state.skipRecursive == Just RecursiveStep{tuplesetRelation, computedRelation} =
        pure (Right [])
    | otherwise = do
        case lookupRelation graph objectType tuplesetRelation of
            Left err -> pure (Left err)
            Right tuplesetDefinition -> do
                collected <-
                    traverse
                        ( \allowed -> do
                            if allowed.objectType == objectType && computedRelation == currentRelation
                                then evalRecursiveUserset allowed
                                else do
                                    usersetObjects <- evalRelation consistencyStore tupleStore graph context revision consistency subject allowed.objectType computedRelation state
                                    case usersetObjects of
                                        Left err -> pure (Left err)
                                        Right objects -> do
                                            let subjects = concatMap (subjectsForAllowed allowed) objects
                                            rows <- readRowsForSubjects tupleStore revision objectType tuplesetRelation subjects
                                            pure (applyRows objects <$> rows)
                        )
                        (Set.toAscList tuplesetDefinition.allowedSubjects)
                pure (mergeLookupObjects . concat <$> sequence collected)
  where
    recursiveStep = RecursiveStep{tuplesetRelation, computedRelation}
    evalRecursiveUserset allowed = do
        seeds <-
            evalRelation
                consistencyStore
                tupleStore
                graph
                context
                revision
                consistency
                subject
                allowed.objectType
                computedRelation
                state{skipRecursive = Just recursiveStep}
        case seeds of
            Left err -> pure (Left err)
            Right seedObjects ->
                expandRecursive allowed (mergeLookupObjects seedObjects) Map.empty 0
    subjectsForAllowed allowed LookupObject{object} =
        SubjectId object
            : case allowed.relation of
                Nothing -> []
                Just relation -> [SubjectSet object relation]
    expandRecursive allowed frontier seen depth
        | depth >= maxDepth = pure (Left ResolutionLimitExceeded)
        | null frontier = pure (Right (Map.elems seen))
        | otherwise = do
            rows <- readRowsForSubjects tupleStore revision objectType tuplesetRelation (concatMap (subjectsForAllowed allowed) frontier)
            case rows of
                Left err -> pure (Left err)
                Right tupleRows -> do
                    let found = mergeLookupObjects (applyRows frontier tupleRows)
                        seenWithFrontier = insertObjects frontier seen
                        newObjects = filter (\LookupObject{object} -> Map.notMember object seenWithFrontier) found
                    expandRecursive allowed newObjects (insertObjects newObjects seenWithFrontier) (depth + 1)
    applyRows usersetObjects rows =
        let objectDecisionMap =
                Map.fromListWith combineDecisions [(object, decision) | LookupObject{object, decision} <- usersetObjects]
         in do
                row@TupleRow{tuple} <- rows
                let usersetDecision =
                        case tuple.subject of
                            SubjectId subjectObject ->
                                Map.findWithDefault Allowed subjectObject objectDecisionMap
                            SubjectSet subjectObject _ ->
                                Map.findWithDefault Allowed subjectObject objectDecisionMap
                case includeDecision context tuple.caveat usersetDecision of
                    Nothing -> []
                    Just decision -> [objectFromRowWithDecision row decision]

insertObjects :: [LookupObject] -> Map.Map ObjectRef LookupObject -> Map.Map ObjectRef LookupObject
insertObjects objects objectMap =
    foldl'
        ( \acc current@LookupObject{object} ->
            Map.insertWith
                (\new old -> old{decision = combineDecisions old.decision new.decision})
                object
                current
                acc
        )
        objectMap
        objects

confirmCandidates ::
    (Monad m) =>
    ConsistencyStore m ->
    TupleStore m ->
    ReachabilityGraph ->
    CaveatContext ->
    Consistency ->
    Subject ->
    RelationName ->
    Either EnError [LookupObject] ->
    m (Either EnError [LookupObject])
confirmCandidates _ _ _ _ _ _ _ (Left err) =
    pure (Left err)
confirmCandidates consistencyStore tupleStore graph context consistency subject relation (Right candidates) = do
    confirmed <-
        traverse
            ( \LookupObject{object} -> do
                decision <- check consistencyStore tupleStore graph consistency context subject relation object
                pure (LookupObject object <$> decision)
            )
            candidates
    pure (mergeLookupObjects . filterAllowed <$> sequence confirmed)

readRowsForSubjects ::
    (Monad m) =>
    TupleStore m ->
    Revision ->
    ObjectType ->
    RelationName ->
    [Subject] ->
    m (Either EnError [TupleRow])
readRowsForSubjects _ _ _ _ [] =
    pure (Right [])
readRowsForSubjects tupleStore revision objectType relation subjects = do
    page <-
        tupleStore.readStartingWithUser
            revision
            UsersetQuery
                { queryType = objectType
                , queryRelation = relation
                , querySubjects = subjects
                , queryLimit = pageLimit
                , queryCursor = Nothing
                }
    pure (ensureExhausted page)

ensureExhausted :: TuplePage -> Either EnError [TupleRow]
ensureExhausted TuplePage{rows, state} =
    case state of
        Exhausted -> Right rows
        HasMore (_ :: StoreCursor) -> Left ResolutionLimitExceeded
        Truncated (_ :: StoreCursor) -> Left ResolutionLimitExceeded

lookupRelation :: ReachabilityGraph -> ObjectType -> RelationName -> Either EnError Relation
lookupRelation graph objectType relation =
    case Map.lookup RelationRef{objectType, relation} graph.relations of
        Just found -> Right found
        Nothing -> Left (UnknownRelation (renderRef RelationRef{objectType, relation}))

objectFromRowWithDecision :: TupleRow -> CheckDecision -> LookupObject
objectFromRowWithDecision TupleRow{tuple} decision =
    LookupObject{object = tuple.object, decision}

includeDecision :: CaveatContext -> Maybe TupleCaveat -> CheckDecision -> Maybe CheckDecision
includeDecision context caveat decision =
    case applyDecisionGate (evaluateTupleCaveat context caveat) decision of
        Denied -> Nothing
        allowed -> Just allowed

filterAllowed :: [LookupObject] -> [LookupObject]
filterAllowed =
    filter
        ( \LookupObject{decision} ->
            case decision of
                Denied -> False
                Allowed -> True
                Conditional _ -> True
        )

mergeLookupObjects :: [LookupObject] -> [LookupObject]
mergeLookupObjects objects =
    sortOn (.object) (Map.elems objectMap)
  where
    objectMap =
        foldl'
            ( \acc current@LookupObject{object} ->
                Map.insertWith
                    (\new old -> old{decision = combineDecisions old.decision new.decision})
                    object
                    current
                    acc
            )
            Map.empty
            objects

applyGateToObjects :: CheckDecision -> [LookupObject] -> [LookupObject]
applyGateToObjects gate =
    filterAllowed
        . fmap
            ( \current@LookupObject{decision} ->
                current{decision = applyDecisionGate gate decision}
            )

combineDecisions :: CheckDecision -> CheckDecision -> CheckDecision
combineDecisions left right =
    unionDecisions [left, right]

unionDecisions :: [CheckDecision] -> CheckDecision
unionDecisions decisions
    | Allowed `elem` decisions = Allowed
    | null obligations = Denied
    | otherwise = Conditional (dedupeObligations obligations)
  where
    obligations =
        concatMap
            ( \case
                Conditional current -> current
                _ -> []
            )
            decisions

intersectionDecisions :: [CheckDecision] -> CheckDecision
intersectionDecisions decisions
    | Denied `elem` decisions = Denied
    | all (== Allowed) decisions = Allowed
    | otherwise = Conditional (dedupeObligations obligations)
  where
    obligations =
        concatMap
            ( \case
                Conditional current -> current
                _ -> []
            )
            decisions

applyDecisionGate :: CheckDecision -> CheckDecision -> CheckDecision
applyDecisionGate gate decision =
    intersectionDecisions [gate, decision]

evaluateRewriteCaveat :: CaveatName -> CaveatContext -> CheckDecision
evaluateRewriteCaveat caveat (CaveatContext context)
    | Map.member "requested_autonomy" context = Allowed
    | otherwise = Conditional [CaveatObligation{caveat, missingContext = ["requested_autonomy"]}]

evaluateTupleCaveat :: CaveatContext -> Maybe TupleCaveat -> CheckDecision
evaluateTupleCaveat _ Nothing = Allowed
evaluateTupleCaveat context (Just TupleCaveat{name = caveat@(CaveatName "within_autonomy"), payload}) =
    evaluateWithinAutonomy caveat payload context
evaluateTupleCaveat _ (Just TupleCaveat{name}) =
    Conditional [CaveatObligation{caveat = name, missingContext = []}]

evaluateWithinAutonomy :: CaveatName -> CaveatPayload -> CaveatContext -> CheckDecision
evaluateWithinAutonomy caveat (CaveatPayload payload) (CaveatContext context) =
    case missing of
        [] ->
            if autonomyAllowed && timeAllowed
                then Allowed
                else Denied
        _ -> Conditional [CaveatObligation{caveat, missingContext = missing}]
  where
    requested = Map.lookup "requested_autonomy" context
    granted = Map.lookup "autonomy" payload
    now = Map.lookup "current_time" context
    untilValue = Map.lookup "until" payload
    missing =
        ["requested_autonomy" | requested == Nothing]
            <> ["current_time" | untilValue /= Nothing && now == Nothing]
    autonomyAllowed =
        case (requested, granted) of
            (Just (ValueEnum requestedAutonomy), Just (ValueEnum grantedAutonomy)) ->
                autonomyRank requestedAutonomy <= autonomyRank grantedAutonomy
            (Just (ValueText requestedAutonomy), Just (ValueText grantedAutonomy)) ->
                autonomyRank requestedAutonomy <= autonomyRank grantedAutonomy
            _ -> False
    timeAllowed =
        case (now, untilValue) of
            (_, Nothing) -> True
            (Just (ValueTimestamp currentTime), Just (ValueTimestamp expiryTime)) ->
                currentTime <= expiryTime
            _ -> False

autonomyRank :: Text -> Int
autonomyRank value =
    case value of
        "read" -> 0
        "view" -> 0
        "act" -> 1
        "admin" -> 2
        _ -> maxBound

dedupeObligations :: [CaveatObligation] -> [CaveatObligation]
dedupeObligations =
    foldl'
        ( \acc obligation ->
            if obligation `elem` acc then acc else acc <> [obligation]
        )
        []

pageLookup :: LookupLimit -> Maybe LookupCursor -> [LookupObject] -> LookupPage
pageLookup (LookupLimit rawLimit) cursor objects =
    let limit = max 0 rawLimit
        start = maybe 0 decodeCursor cursor
        capped = take resultCap objects
        visible = take limit (drop start capped)
        next = start + length visible
        state
            | next < length capped = LookupHasMore (LookupCursor (showText next))
            | length objects > resultCap = LookupTruncated (LookupCursor (showText resultCap))
            | otherwise = LookupExhausted
     in LookupPage{objects = visible, state}

decodeCursor :: LookupCursor -> Int
decodeCursor (LookupCursor cursorText) =
    case reads (Text.unpack cursorText) of
        [(value, "")] -> max 0 value
        _ -> 0

showText :: (Show a) => a -> Text
showText =
    Text.pack . show

renderRef :: RelationRef -> Text
renderRef RelationRef{objectType = ObjectType objectType, relation = RelationName relation} =
    objectType <> "#" <> relation
