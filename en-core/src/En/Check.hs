-- | Forward evaluation: does a subject have a permission on an object?
module En.Check (
    CheckDecision (..),
    CaveatObligation (..),
    BatchPair (..),
    CheckCacheEnv (..),
    check,
    checkCached,
    checkMany,
) where

import Control.Monad (foldM)
import Data.Map.Strict qualified as Map
import Data.Text (Text)
import Effectful (Eff, IOE, liftIO, (:>))
import Effectful.Error.Static (Error, throwError)

import En.Cache (Cache, SubproblemKey (..), insertCache, lookupCache)
import En.Caveat (evaluateCaveat)
import En.Decision (CaveatObligation (..), CheckDecision (..))
import En.Decision qualified as Decision
import En.Effect.ConsistencyStore (ConsistencyStore, ResolvedConsistency (..), resolveConsistency)
import En.Effect.TupleStore (PageState (..), StoreCursor, TuplePage (..), TupleRow (..), TupleStore, readObjectRelation)
import En.Error (EnError (..))
import En.Reachability (ReachabilityGraph (..), RelationRef (..))
import En.Revision (Consistency, DatastoreId, Revision (..))
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

data CheckCacheEnv = CheckCacheEnv
    { cacheDatastoreId :: !DatastoreId
    , cacheDecisions :: !(Cache SubproblemKey CheckDecision)
    }

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
    (result, _memo) <- runCheckMemo graph context revision subject permission object Map.empty
    either throwError pure result

{- | Cached variant of 'check'. Cache hits are keyed by datastore id, schema
hash, resolved revision, subject, relation, object, and caveat context.
-}
checkCached ::
    (ConsistencyStore :> es, TupleStore :> es, IOE :> es, Error EnError :> es) =>
    CheckCacheEnv ->
    ReachabilityGraph ->
    Consistency ->
    CaveatContext ->
    Subject ->
    RelationName ->
    ObjectRef ->
    Eff es CheckDecision
checkCached cacheEnv graph consistency context subject permission object = do
    ResolvedConsistency{revision} <- resolveConsistency consistency
    (result, _memo) <- runCheckMemoWithCache (Just (decisionCacheOps cacheEnv graph context)) graph context revision subject permission object Map.empty
    either throwError pure result

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
    runCheckMemoWithCache Nothing graph context revision subject permission object

runCheckMemoWithCache ::
    (TupleStore :> es) =>
    Maybe (DecisionCacheOps es) ->
    ReachabilityGraph ->
    CaveatContext ->
    Revision ->
    Subject ->
    RelationName ->
    ObjectRef ->
    CheckMemo ->
    Eff es (Either EnError CheckDecision, CheckMemo)
runCheckMemoWithCache cacheOps graph context revision subject permission object =
    evalRelationMemo cacheOps graph context revision subject object permission initialState

data DecisionCacheOps es = DecisionCacheOps
    { lookupDecision :: !(Revision -> Subject -> RelationName -> ObjectRef -> Eff es (Maybe CheckDecision))
    , insertDecision :: !(Revision -> Subject -> RelationName -> ObjectRef -> CheckDecision -> Eff es ())
    }

decisionCacheOps ::
    (IOE :> es) =>
    CheckCacheEnv ->
    ReachabilityGraph ->
    CaveatContext ->
    DecisionCacheOps es
decisionCacheOps CheckCacheEnv{cacheDatastoreId, cacheDecisions} graph context =
    DecisionCacheOps
        { lookupDecision = \revision subject relation object ->
            liftIO (lookupCache cacheDecisions (cacheKey revision subject relation object))
        , insertDecision = \revision subject relation object decision ->
            liftIO (insertCache cacheDecisions (cacheKey revision subject relation object) decision)
        }
  where
    cacheKey revision subject relation object =
        SubproblemKey
            { datastoreId = cacheDatastoreId
            , schemaHash = graph.hash
            , revision
            , subject
            , relation
            , object
            , context
            }

evalRelationMemo ::
    (TupleStore :> es) =>
    Maybe (DecisionCacheOps es) ->
    ReachabilityGraph ->
    CaveatContext ->
    Revision ->
    Subject ->
    ObjectRef ->
    RelationName ->
    EvalState ->
    CheckMemo ->
    Eff es (Either EnError CheckDecision, CheckMemo)
evalRelationMemo cacheOps graph context revision subject object relation state memo
    | state.depth >= maxDepth =
        pure (Left ResolutionLimitExceeded, memo)
    | subproblem `elem` state.visited =
        pure (Left ResolutionLimitExceeded, memo)
    | otherwise =
        case Map.lookup key memo of
            Just decision ->
                pure (Right decision, memo)
            Nothing -> do
                external <- lookupExternalDecision
                case external of
                    Just decision ->
                        pure (Right decision, Map.insert key decision memo)
                    Nothing ->
                        case Map.lookup ref graph.relations of
                            Nothing ->
                                pure (Left (UnknownRelation (renderRef ref)), memo)
                            Just schemaRelation -> do
                                (result, memo') <-
                                    evalRewriteMemo
                                        cacheOps
                                        graph
                                        context
                                        revision
                                        subject
                                        object
                                        relation
                                        schemaRelation.rewrite
                                        EvalState{depth = state.depth + 1, visited = subproblem : state.visited}
                                        memo
                                case result of
                                    Right decision -> do
                                        insertExternalDecision decision
                                        pure (result, Map.insert key decision memo')
                                    Left _ ->
                                        pure (result, memo')
  where
    ref = RelationRef{objectType = object.objectType, relation}
    subproblem = Subproblem{subject, object, relation}
    key = MemoKey revision.revisionEncoding subproblem
    lookupExternalDecision =
        case cacheOps of
            Nothing -> pure Nothing
            Just ops -> ops.lookupDecision revision subject relation object
    insertExternalDecision decision =
        case cacheOps of
            Nothing -> pure ()
            Just ops -> ops.insertDecision revision subject relation object decision

evalRewriteMemo ::
    (TupleStore :> es) =>
    Maybe (DecisionCacheOps es) ->
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
evalRewriteMemo cacheOps graph context revision subject object currentRelation rewrite state memo =
    case rewrite of
        This ->
            evalThisMemo cacheOps graph context revision subject object currentRelation state memo
        ComputedUserset relation ->
            evalRelationMemo cacheOps graph context revision subject object relation state memo
        TupleToUserset tuplesetRelation computedRelation ->
            evalTupleToUsersetMemo cacheOps graph context revision subject object tuplesetRelation computedRelation state memo
        Union rewrites -> do
            (decisions, memo') <-
                evalRewriteListMemo cacheOps graph context revision subject object currentRelation rewrites state memo
            pure (Decision.union <$> sequence decisions, memo')
        Intersection rewrites -> do
            (decisions, memo') <-
                evalRewriteListMemo cacheOps graph context revision subject object currentRelation rewrites state memo
            pure (Decision.intersection <$> sequence decisions, memo')
        Exclusion base subtractRewrite -> do
            (baseDecision, memo') <- evalRewriteMemo cacheOps graph context revision subject object currentRelation base state memo
            case baseDecision of
                Left err -> pure (Left err, memo')
                Right Denied -> pure (Right Denied, memo')
                Right (Conditional obligations) -> pure (Right (Conditional obligations), memo')
                Right Allowed -> do
                    (subtractDecision, memo'') <- evalRewriteMemo cacheOps graph context revision subject object currentRelation subtractRewrite state memo'
                    pure (Decision.exclusion <$> subtractDecision, memo'')
        Caveated caveat rewriteInner -> do
            (inner, memo') <- evalRewriteMemo cacheOps graph context revision subject object currentRelation rewriteInner state memo
            pure (applyRewriteCaveat graph context caveat =<< inner, memo')

evalRewriteListMemo ::
    (TupleStore :> es) =>
    Maybe (DecisionCacheOps es) ->
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
evalRewriteListMemo cacheOps graph context revision subject object currentRelation rewrites state memo =
    foldM step ([], memo) rewrites
  where
    step (decisions, currentMemo) rewrite = do
        (decision, memo') <- evalRewriteMemo cacheOps graph context revision subject object currentRelation rewrite state currentMemo
        pure (decisions <> [decision], memo')

evalThisMemo ::
    (TupleStore :> es) =>
    Maybe (DecisionCacheOps es) ->
    ReachabilityGraph ->
    CaveatContext ->
    Revision ->
    Subject ->
    ObjectRef ->
    RelationName ->
    EvalState ->
    CheckMemo ->
    Eff es (Either EnError CheckDecision, CheckMemo)
evalThisMemo cacheOps graph context revision subject object relation state memo
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
                    (decision, memo'') <- evalRelationMemo cacheOps graph context revision subject subjectObject subjectRelation state memo'
                    pure (decisions <> [decision >>= applyTupleCaveat graph context tuple.caveat], memo'')
                SubjectWildcard _ ->
                    pure (decisions <> [Right Denied], memo')

evalTupleToUsersetMemo ::
    (TupleStore :> es) =>
    Maybe (DecisionCacheOps es) ->
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
evalTupleToUsersetMemo cacheOps graph context revision subject object tuplesetRelation computedRelation state memo = do
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
                (decision, memo'') <- evalRelationMemo cacheOps graph context revision subject subjectObject computedRelation state memo'
                pure (decisions <> [applyRowGate tuple decision], memo'')
            SubjectSet subjectObject subjectRelation -> do
                (decision, memo'') <- evalRelationMemo cacheOps graph context revision subject subjectObject subjectRelation state memo'
                pure (decisions <> [applyRowGate tuple decision], memo'')
            SubjectWildcard _ ->
                pure (decisions <> [Right Denied], memo')

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
