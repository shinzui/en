-- | Forward evaluation: does a subject have a permission on an object?
module En.Check (
    CheckDecision (..),
    CaveatObligation (..),
    BatchPair (..),
    check,
    checkMany,
) where

import Control.Monad (foldM)
import Data.Map.Strict qualified as Map
import Data.Text (Text)
import Effectful (Eff, (:>))
import Effectful.Error.Static (Error, throwError)

import En.Caveat (evaluateCaveat)
import En.Decision (CaveatObligation (..), CheckDecision (..))
import En.Decision qualified as Decision
import En.Effect.ConsistencyStore (ConsistencyStore, ResolvedConsistency (..), resolveConsistency)
import En.Effect.TupleStore (PageState (..), StoreCursor, TuplePage (..), TupleRow (..), TupleStore, readObjectRelation)
import En.Error (EnError (..))
import En.Reachability (ReachabilityGraph (..), RelationRef (..))
import En.Revision (Consistency, Revision (..))
import En.Schema (CaveatName (..), ObjectType (..), Relation (..), RelationName (..), Rewrite (..))
import En.Tuple (
    CaveatContext (..),
    CaveatPayload (..),
    ObjectRef (..),
    Subject (..),
    Tuple (..),
    TupleCaveat (..),
 )

{- | One (subject, permission, object) question in a batch.

A 'checkMany' call evaluates every pair against one resolved consistency
snapshot and one caveat context, returning decisions in input order.
-}
data BatchPair = BatchPair
    { subject :: !Subject
    , permission :: !RelationName
    , object :: !ObjectRef
    }
    deriving stock (Eq, Ord, Show)

{- | Does @subject@ have @permission@ on @object@? Forward evaluation over the
reachability graph and the tuple store.
-}
check ::
    (ConsistencyStore :> es, TupleStore :> es, Error EnError :> es) =>
    ReachabilityGraph ->
    Consistency ->
    CaveatContext ->
    Subject ->
    RelationName ->
    ObjectRef ->
    Eff es CheckDecision
check graph consistency context subject permission object = do
    ResolvedConsistency{revision} <- resolveConsistency consistency
    either throwError pure =<< runCheck graph context revision subject permission object

{- | Evaluate many checks against one resolved consistency snapshot.

The engine resolves consistency once, evaluates distinct pairs sequentially
through a within-call memo, and returns decisions in the same order as the
input. Errors after consistency resolution fail closed for only that pair by
returning 'Denied'. Transport-layer handlers remain responsible for bounding
batch size and adding any IO-specific concurrency.
-}
checkMany ::
    (ConsistencyStore :> es, TupleStore :> es) =>
    ReachabilityGraph ->
    Consistency ->
    CaveatContext ->
    [BatchPair] ->
    Eff es [CheckDecision]
checkMany graph consistency context pairs = do
    ResolvedConsistency{revision} <- resolveConsistency consistency
    (decisionsByPair, _memo) <-
        foldM
            (evaluateDistinct revision)
            (Map.empty, Map.empty)
            (dedupePairs pairs)
    pure [Map.findWithDefault Denied pair decisionsByPair | pair <- pairs]
  where
    evaluateDistinct revision (decisionsByPair, memo) pair = do
        (result, memo') <-
            runCheckMemo graph context revision pair.subject pair.permission pair.object memo
        let decision =
                either (const Denied) id result
        pure (Map.insert pair decision decisionsByPair, memo')

dedupePairs :: [BatchPair] -> [BatchPair]
dedupePairs =
    reverse . fst . foldl' step ([], Map.empty)
  where
    step (ordered, seen) pair
        | Map.member pair seen = (ordered, seen)
        | otherwise = (pair : ordered, Map.insert pair () seen)

runCheck ::
    (TupleStore :> es) =>
    ReachabilityGraph ->
    CaveatContext ->
    Revision ->
    Subject ->
    RelationName ->
    ObjectRef ->
    Eff es (Either EnError CheckDecision)
runCheck graph context revision subject permission object =
    evalRelation graph context revision subject object permission initialState

data EvalState = EvalState
    { depth :: !Int
    , visited :: ![Subproblem]
    }

data Subproblem = Subproblem
    { subject :: !Subject
    , object :: !ObjectRef
    , relation :: !RelationName
    }
    deriving stock (Eq, Ord, Show)

data MemoKey = MemoKey
    { revision :: !Text
    , subproblem :: !Subproblem
    }
    deriving stock (Eq, Ord, Show)

type CheckMemo = Map.Map MemoKey CheckDecision

initialState :: EvalState
initialState =
    EvalState{depth = 0, visited = []}

maxDepth :: Int
maxDepth = 25

pageLimit :: Int
pageLimit = 1000

evalRelation ::
    (TupleStore :> es) =>
    ReachabilityGraph ->
    CaveatContext ->
    Revision ->
    Subject ->
    ObjectRef ->
    RelationName ->
    EvalState ->
    Eff es (Either EnError CheckDecision)
evalRelation graph context revision subject object relation state
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
                    graph
                    context
                    revision
                    subject
                    object
                    relation
                    schemaRelation.rewrite
                    EvalState{depth = state.depth + 1, visited = subproblem : state.visited}
  where
    ref = RelationRef{objectType = object.objectType, relation}
    subproblem = Subproblem{subject, object, relation}

runCheckMemo ::
    (TupleStore :> es) =>
    ReachabilityGraph ->
    CaveatContext ->
    Revision ->
    Subject ->
    RelationName ->
    ObjectRef ->
    CheckMemo ->
    Eff es (Either EnError CheckDecision, CheckMemo)
runCheckMemo graph context revision subject permission object =
    evalRelationMemo graph context revision subject object permission initialState

evalRelationMemo ::
    (TupleStore :> es) =>
    ReachabilityGraph ->
    CaveatContext ->
    Revision ->
    Subject ->
    ObjectRef ->
    RelationName ->
    EvalState ->
    CheckMemo ->
    Eff es (Either EnError CheckDecision, CheckMemo)
evalRelationMemo graph context revision subject object relation state memo
    | state.depth >= maxDepth =
        pure (Left ResolutionLimitExceeded, memo)
    | subproblem `elem` state.visited =
        pure (Left ResolutionLimitExceeded, memo)
    | otherwise =
        case Map.lookup key memo of
            Just decision ->
                pure (Right decision, memo)
            Nothing ->
                case Map.lookup ref graph.relations of
                    Nothing ->
                        pure (Left (UnknownRelation (renderRef ref)), memo)
                    Just schemaRelation -> do
                        (result, memo') <-
                            evalRewriteMemo
                                graph
                                context
                                revision
                                subject
                                object
                                relation
                                schemaRelation.rewrite
                                EvalState{depth = state.depth + 1, visited = subproblem : state.visited}
                                memo
                        let memo'' =
                                case result of
                                    Right decision -> Map.insert key decision memo'
                                    Left _ -> memo'
                        pure (result, memo'')
  where
    ref = RelationRef{objectType = object.objectType, relation}
    subproblem = Subproblem{subject, object, relation}
    key = MemoKey revision.revisionEncoding subproblem

evalRewriteMemo ::
    (TupleStore :> es) =>
    ReachabilityGraph ->
    CaveatContext ->
    Revision ->
    Subject ->
    ObjectRef ->
    RelationName ->
    Rewrite ->
    EvalState ->
    CheckMemo ->
    Eff es (Either EnError CheckDecision, CheckMemo)
evalRewriteMemo graph context revision subject object currentRelation rewrite state memo =
    case rewrite of
        This ->
            evalThisMemo graph context revision subject object currentRelation state memo
        ComputedUserset relation ->
            evalRelationMemo graph context revision subject object relation state memo
        TupleToUserset tuplesetRelation computedRelation ->
            evalTupleToUsersetMemo graph context revision subject object tuplesetRelation computedRelation state memo
        Union rewrites -> do
            (decisions, memo') <-
                evalRewriteListMemo graph context revision subject object currentRelation rewrites state memo
            pure (Decision.union <$> sequence decisions, memo')
        Intersection rewrites -> do
            (decisions, memo') <-
                evalRewriteListMemo graph context revision subject object currentRelation rewrites state memo
            pure (Decision.intersection <$> sequence decisions, memo')
        Exclusion base subtractRewrite -> do
            (baseDecision, memo') <- evalRewriteMemo graph context revision subject object currentRelation base state memo
            case baseDecision of
                Left err -> pure (Left err, memo')
                Right Denied -> pure (Right Denied, memo')
                Right (Conditional obligations) -> pure (Right (Conditional obligations), memo')
                Right Allowed -> do
                    (subtractDecision, memo'') <- evalRewriteMemo graph context revision subject object currentRelation subtractRewrite state memo'
                    pure (Decision.exclusion <$> subtractDecision, memo'')
        Caveated caveat rewriteInner -> do
            (inner, memo') <- evalRewriteMemo graph context revision subject object currentRelation rewriteInner state memo
            pure (applyRewriteCaveat graph context caveat =<< inner, memo')

evalRewriteListMemo ::
    (TupleStore :> es) =>
    ReachabilityGraph ->
    CaveatContext ->
    Revision ->
    Subject ->
    ObjectRef ->
    RelationName ->
    [Rewrite] ->
    EvalState ->
    CheckMemo ->
    Eff es ([Either EnError CheckDecision], CheckMemo)
evalRewriteListMemo graph context revision subject object currentRelation rewrites state memo =
    foldM step ([], memo) rewrites
  where
    step (decisions, currentMemo) rewrite = do
        (decision, memo') <- evalRewriteMemo graph context revision subject object currentRelation rewrite state currentMemo
        pure (decisions <> [decision], memo')

evalThisMemo ::
    (TupleStore :> es) =>
    ReachabilityGraph ->
    CaveatContext ->
    Revision ->
    Subject ->
    ObjectRef ->
    RelationName ->
    EvalState ->
    CheckMemo ->
    Eff es (Either EnError CheckDecision, CheckMemo)
evalThisMemo graph context revision subject object relation state memo
    | state.depth >= maxDepth =
        pure (Left ResolutionLimitExceeded, memo)
    | otherwise = do
        page <- readObjectRelation revision object relation pageLimit Nothing
        case ensureExhausted page of
            Left err -> pure (Left err, memo)
            Right rows -> do
                (decisions, memo') <- foldM rowDecision ([], memo) rows
                pure (Decision.union <$> sequence decisions, memo')
  where
    rowDecision (decisions, memo') TupleRow{tuple}
        | tuple.subject == subject || wildcardMatches tuple.subject subject =
            pure (decisions <> [applyTupleCaveat graph context tuple.caveat Allowed], memo')
        | otherwise =
            case tuple.subject of
                SubjectId _ ->
                    pure (decisions <> [Right Denied], memo')
                SubjectSet subjectObject subjectRelation -> do
                    (decision, memo'') <- evalRelationMemo graph context revision subject subjectObject subjectRelation state memo'
                    pure (decisions <> [decision >>= applyTupleCaveat graph context tuple.caveat], memo'')
                SubjectWildcard _ ->
                    pure (decisions <> [Right Denied], memo')

evalTupleToUsersetMemo ::
    (TupleStore :> es) =>
    ReachabilityGraph ->
    CaveatContext ->
    Revision ->
    Subject ->
    ObjectRef ->
    RelationName ->
    RelationName ->
    EvalState ->
    CheckMemo ->
    Eff es (Either EnError CheckDecision, CheckMemo)
evalTupleToUsersetMemo graph context revision subject object tuplesetRelation computedRelation state memo = do
    page <- readObjectRelation revision object tuplesetRelation pageLimit Nothing
    case ensureExhausted page of
        Left err -> pure (Left err, memo)
        Right rows -> do
            (decisions, memo') <- foldM rowDecision ([], memo) rows
            pure (Decision.union <$> sequence decisions, memo')
  where
    rowDecision (decisions, memo') TupleRow{tuple} =
        case tuple.subject of
            SubjectId subjectObject -> do
                (decision, memo'') <- evalRelationMemo graph context revision subject subjectObject computedRelation state memo'
                pure (decisions <> [applyRowGate tuple decision], memo'')
            SubjectSet subjectObject subjectRelation -> do
                (decision, memo'') <- evalRelationMemo graph context revision subject subjectObject subjectRelation state memo'
                pure (decisions <> [applyRowGate tuple decision], memo'')
            SubjectWildcard _ ->
                pure (decisions <> [Right Denied], memo')

    applyRowGate tuple =
        (>>= applyTupleCaveat graph context tuple.caveat)

evalRewrite ::
    (TupleStore :> es) =>
    ReachabilityGraph ->
    CaveatContext ->
    Revision ->
    Subject ->
    ObjectRef ->
    RelationName ->
    Rewrite ->
    EvalState ->
    Eff es (Either EnError CheckDecision)
evalRewrite graph context revision subject object currentRelation rewrite state =
    case rewrite of
        This ->
            evalThis graph context revision subject object currentRelation state
        ComputedUserset relation ->
            evalRelation graph context revision subject object relation state
        TupleToUserset tuplesetRelation computedRelation ->
            evalTupleToUserset graph context revision subject object tuplesetRelation computedRelation state
        Union rewrites -> do
            decisions <- traverse (\current -> evalRewrite graph context revision subject object currentRelation current state) rewrites
            pure (Decision.union <$> sequence decisions)
        Intersection rewrites -> do
            decisions <- traverse (\current -> evalRewrite graph context revision subject object currentRelation current state) rewrites
            pure (Decision.intersection <$> sequence decisions)
        Exclusion base subtractRewrite -> do
            baseDecision <- evalRewrite graph context revision subject object currentRelation base state
            case baseDecision of
                Left err -> pure (Left err)
                Right Denied -> pure (Right Denied)
                Right (Conditional obligations) -> pure (Right (Conditional obligations))
                Right Allowed -> do
                    subtractDecision <- evalRewrite graph context revision subject object currentRelation subtractRewrite state
                    pure (Decision.exclusion <$> subtractDecision)
        Caveated caveat rewriteInner -> do
            inner <- evalRewrite graph context revision subject object currentRelation rewriteInner state
            pure (applyRewriteCaveat graph context caveat =<< inner)

evalThis ::
    (TupleStore :> es) =>
    ReachabilityGraph ->
    CaveatContext ->
    Revision ->
    Subject ->
    ObjectRef ->
    RelationName ->
    EvalState ->
    Eff es (Either EnError CheckDecision)
evalThis graph context revision subject object relation state
    | state.depth >= maxDepth =
        pure (Left ResolutionLimitExceeded)
    | otherwise = do
        page <- readObjectRelation revision object relation pageLimit Nothing
        case ensureExhausted page of
            Left err -> pure (Left err)
            Right rows -> do
                decisions <- traverse rowDecision rows
                pure (Decision.union <$> sequence decisions)
  where
    rowDecision TupleRow{tuple}
        | tuple.subject == subject || wildcardMatches tuple.subject subject =
            pure (applyTupleCaveat graph context tuple.caveat Allowed)
        | otherwise =
            case tuple.subject of
                SubjectId _ ->
                    pure (Right Denied)
                SubjectSet subjectObject subjectRelation ->
                    fmap
                        (>>= applyTupleCaveat graph context tuple.caveat)
                        (evalRelation graph context revision subject subjectObject subjectRelation state)
                SubjectWildcard _ ->
                    pure (Right Denied)

evalTupleToUserset ::
    (TupleStore :> es) =>
    ReachabilityGraph ->
    CaveatContext ->
    Revision ->
    Subject ->
    ObjectRef ->
    RelationName ->
    RelationName ->
    EvalState ->
    Eff es (Either EnError CheckDecision)
evalTupleToUserset graph context revision subject object tuplesetRelation computedRelation state = do
    page <- readObjectRelation revision object tuplesetRelation pageLimit Nothing
    case ensureExhausted page of
        Left err -> pure (Left err)
        Right rows -> do
            decisions <-
                traverse
                    ( \TupleRow{tuple} ->
                        case tuple.subject of
                            SubjectId subjectObject ->
                                applyRowGate tuple <$> evalRelation graph context revision subject subjectObject computedRelation state
                            SubjectSet subjectObject subjectRelation ->
                                applyRowGate tuple <$> evalRelation graph context revision subject subjectObject subjectRelation state
                            SubjectWildcard _ ->
                                pure (Right Denied)
                    )
                    rows
            pure (Decision.union <$> sequence decisions)
  where
    applyRowGate tuple =
        (>>= applyTupleCaveat graph context tuple.caveat)

wildcardMatches :: Subject -> Subject -> Bool
wildcardMatches tupleSubject checkedSubject =
    case (tupleSubject, checkedSubject) of
        (SubjectWildcard wildcardType, SubjectId ObjectRef{objectType}) ->
            wildcardType == objectType
        _ -> False

ensureExhausted :: TuplePage -> Either EnError [TupleRow]
ensureExhausted TuplePage{rows, state} =
    case state of
        Exhausted -> Right rows
        HasMore (_ :: StoreCursor) -> Left ResolutionLimitExceeded
        Truncated (_ :: StoreCursor) -> Left ResolutionLimitExceeded

applyRewriteCaveat :: ReachabilityGraph -> CaveatContext -> CaveatName -> CheckDecision -> Either EnError CheckDecision
applyRewriteCaveat graph context caveat decision = do
    gate <- evaluateNamedCaveat graph context caveat (CaveatPayload Map.empty)
    pure (Decision.applyGate gate decision)

applyTupleCaveat :: ReachabilityGraph -> CaveatContext -> Maybe TupleCaveat -> CheckDecision -> Either EnError CheckDecision
applyTupleCaveat _ _ Nothing decision =
    Right decision
applyTupleCaveat graph context (Just TupleCaveat{name, payload}) decision = do
    gate <- evaluateNamedCaveat graph context name payload
    pure (Decision.applyGate gate decision)

evaluateNamedCaveat :: ReachabilityGraph -> CaveatContext -> CaveatName -> CaveatPayload -> Either EnError CheckDecision
evaluateNamedCaveat graph context caveat payload =
    case Map.lookup caveat graph.caveats of
        Nothing -> Left (UnknownRelation ("unknown caveat: " <> caveatText caveat))
        Just definition -> Right (evaluateCaveat definition payload context)

renderRef :: RelationRef -> Text
renderRef RelationRef{objectType = ObjectType objectType, relation = RelationName relation} =
    objectType <> "#" <> relation

caveatText :: CaveatName -> Text
caveatText (CaveatName text) =
    text
