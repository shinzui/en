-- | Forward evaluation: does a subject have a permission on an object?
module En.Check (
    CheckDecision (..),
    CaveatObligation (..),
    check,
) where

import Data.Map.Strict qualified as Map
import Data.Text (Text)

import En.Effect.ConsistencyStore (ConsistencyStore (..), ResolvedConsistency (..))
import En.Effect.TupleStore (PageState (..), StoreCursor, TuplePage (..), TupleRow (..), TupleStore (..))
import En.Error (EnError (..))
import En.Reachability (ReachabilityGraph (..), RelationRef (..))
import En.Revision (Consistency, Revision)
import En.Schema (CaveatName (..), ObjectType (..), Relation (..), RelationName (..), Rewrite (..))
import En.Tuple (
    CaveatContext (..),
    CaveatPayload (..),
    CaveatValue (..),
    ObjectRef (..),
    Subject (..),
    Tuple (..),
    TupleCaveat (..),
 )

-- | A caveat that could not be reduced to an unconditional answer.
data CaveatObligation = CaveatObligation
    { caveat :: !CaveatName
    , missingContext :: ![Text]
    }
    deriving stock (Eq, Show)

{- | Three-valued authorization result. 'Conditional' means the graph path exists
but one or more caveats need request context before the caller may treat it as
allowed.
-}
data CheckDecision
    = Allowed
    | Denied
    | Conditional ![CaveatObligation]
    deriving stock (Eq, Show)

{- | Does @subject@ have @permission@ on @object@? Forward evaluation over the
reachability graph and the tuple store.
-}
check ::
    (Monad m) =>
    ConsistencyStore m ->
    TupleStore m ->
    ReachabilityGraph ->
    Consistency ->
    CaveatContext ->
    Subject ->
    RelationName ->
    ObjectRef ->
    m (Either EnError CheckDecision)
check consistencyStore tupleStore graph consistency context subject permission object = do
    resolved <- consistencyStore.resolveConsistency consistency
    case resolved of
        Left err -> pure (Left err)
        Right ResolvedConsistency{revision} ->
            runCheck tupleStore graph context revision subject permission object

runCheck ::
    (Monad m) =>
    TupleStore m ->
    ReachabilityGraph ->
    CaveatContext ->
    Revision ->
    Subject ->
    RelationName ->
    ObjectRef ->
    m (Either EnError CheckDecision)
runCheck tupleStore graph context revision subject permission object =
    evalRelation tupleStore graph context revision subject object permission initialState

data EvalState = EvalState
    { depth :: !Int
    , visited :: ![Subproblem]
    }

data Subproblem = Subproblem
    { subject :: !Subject
    , object :: !ObjectRef
    , relation :: !RelationName
    }
    deriving stock (Eq, Show)

initialState :: EvalState
initialState =
    EvalState{depth = 0, visited = []}

maxDepth :: Int
maxDepth = 25

pageLimit :: Int
pageLimit = 1000

evalRelation ::
    (Monad m) =>
    TupleStore m ->
    ReachabilityGraph ->
    CaveatContext ->
    Revision ->
    Subject ->
    ObjectRef ->
    RelationName ->
    EvalState ->
    m (Either EnError CheckDecision)
evalRelation tupleStore graph context revision subject object relation state
    | state.depth >= maxDepth =
        pure (Left ResolutionLimitExceeded)
    | subproblem `elem` state.visited =
        pure (Left ResolutionLimitExceeded)
    | otherwise =
        case Map.lookup ref graph.relations of
            Nothing ->
                pure (Left (UnknownRelation (renderRef ref)))
            Just schemaRelation ->
                evalRewrite
                    tupleStore
                    graph
                    context
                    revision
                    subject
                    object
                    schemaRelation.rewrite
                    EvalState{depth = state.depth + 1, visited = subproblem : state.visited}
  where
    ref = RelationRef{objectType = object.objectType, relation}
    subproblem = Subproblem{subject, object, relation}

evalRewrite ::
    (Monad m) =>
    TupleStore m ->
    ReachabilityGraph ->
    CaveatContext ->
    Revision ->
    Subject ->
    ObjectRef ->
    Rewrite ->
    EvalState ->
    m (Either EnError CheckDecision)
evalRewrite tupleStore graph context revision subject object rewrite state =
    case rewrite of
        This ->
            evalThis tupleStore graph context revision subject object state
        ComputedUserset relation ->
            evalRelation tupleStore graph context revision subject object relation state
        TupleToUserset tuplesetRelation computedRelation ->
            evalTupleToUserset tupleStore graph context revision subject object tuplesetRelation computedRelation state
        Union rewrites -> do
            decisions <- traverse (\current -> evalRewrite tupleStore graph context revision subject object current state) rewrites
            pure (unionDecisions <$> sequence decisions)
        Intersection rewrites -> do
            decisions <- traverse (\current -> evalRewrite tupleStore graph context revision subject object current state) rewrites
            pure (intersectionDecisions <$> sequence decisions)
        Exclusion base subtractRewrite -> do
            baseDecision <- evalRewrite tupleStore graph context revision subject object base state
            case baseDecision of
                Left err -> pure (Left err)
                Right Denied -> pure (Right Denied)
                Right (Conditional obligations) -> pure (Right (Conditional obligations))
                Right Allowed -> do
                    subtractDecision <- evalRewrite tupleStore graph context revision subject object subtractRewrite state
                    pure (exclusionDecision <$> subtractDecision)
        Caveated caveat rewriteInner -> do
            inner <- evalRewrite tupleStore graph context revision subject object rewriteInner state
            pure (applyDecisionGate (evaluateRewriteCaveat caveat context) <$> inner)

evalThis ::
    (Monad m) =>
    TupleStore m ->
    ReachabilityGraph ->
    CaveatContext ->
    Revision ->
    Subject ->
    ObjectRef ->
    EvalState ->
    m (Either EnError CheckDecision)
evalThis tupleStore graph context revision subject object state
    | state.depth >= maxDepth =
        pure (Left ResolutionLimitExceeded)
    | otherwise = do
        page <- tupleStore.readObjectRelation revision object stateRelation pageLimit Nothing
        case ensureExhausted page of
            Left err -> pure (Left err)
            Right rows -> do
                decisions <- traverse rowDecision rows
                pure (unionDecisions <$> sequence decisions)
  where
    stateRelation =
        case state.visited of
            Subproblem{relation} : _ -> relation
            [] -> error "internal error: evalThis requires a current relation"
    rowDecision TupleRow{tuple}
        | tuple.subject == subject =
            pure (Right (applyDecisionGate (evaluateTupleCaveat context tuple.caveat) Allowed))
        | otherwise =
            case tuple.subject of
                SubjectId _ ->
                    pure (Right Denied)
                SubjectSet subjectObject subjectRelation ->
                    fmap
                        (fmap (applyDecisionGate (evaluateTupleCaveat context tuple.caveat)))
                        (evalRelation tupleStore graph context revision subject subjectObject subjectRelation state)

evalTupleToUserset ::
    (Monad m) =>
    TupleStore m ->
    ReachabilityGraph ->
    CaveatContext ->
    Revision ->
    Subject ->
    ObjectRef ->
    RelationName ->
    RelationName ->
    EvalState ->
    m (Either EnError CheckDecision)
evalTupleToUserset tupleStore graph context revision subject object tuplesetRelation computedRelation state = do
    page <- tupleStore.readObjectRelation revision object tuplesetRelation pageLimit Nothing
    case ensureExhausted page of
        Left err -> pure (Left err)
        Right rows -> do
            decisions <-
                traverse
                    ( \TupleRow{tuple} ->
                        case tuple.subject of
                            SubjectId subjectObject ->
                                applyRowGate tuple <$> evalRelation tupleStore graph context revision subject subjectObject computedRelation state
                            SubjectSet subjectObject subjectRelation ->
                                applyRowGate tuple <$> evalRelation tupleStore graph context revision subject subjectObject subjectRelation state
                    )
                    rows
            pure (unionDecisions <$> sequence decisions)
  where
    applyRowGate tuple =
        fmap (applyDecisionGate (evaluateTupleCaveat context tuple.caveat))

ensureExhausted :: TuplePage -> Either EnError [TupleRow]
ensureExhausted TuplePage{rows, state} =
    case state of
        Exhausted -> Right rows
        HasMore (_ :: StoreCursor) -> Left ResolutionLimitExceeded
        Truncated (_ :: StoreCursor) -> Left ResolutionLimitExceeded

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

exclusionDecision :: CheckDecision -> CheckDecision
exclusionDecision =
    \case
        Allowed -> Denied
        Denied -> Allowed
        Conditional obligations -> Conditional obligations

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

renderRef :: RelationRef -> Text
renderRef RelationRef{objectType = ObjectType objectType, relation = RelationName relation} =
    objectType <> "#" <> relation
