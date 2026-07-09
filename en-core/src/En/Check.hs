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
import En.Effect.TupleStore (PageState (..), TuplePage (..), TupleRow (..), TupleStore, UsersetQuery (..), probeTuples, readObjectRelation, readStartingWithUser)
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
through a within-call memo, and returns one result per input pair, in input
order.

The two ways a batch can fail are kept apart. Resolving consistency is a
request-level step: if it fails, no pair has an answer, and the failure escapes
through whatever error effect the 'ConsistencyStore' interpreter raises, aborting
the batch. Evaluating a pair is pair-level: its failure is returned as a 'Left'
beside the pairs that succeeded, so a caller can tell "denied" from "this one
broke" and decide what to do. The engine deliberately does not decide for them; a
transport that must answer with a decision should fail closed and report 'Denied'.

This function therefore needs no @Error EnError@ capability of its own -- it
raises nothing that is not already raised by the interpreters it runs under, and
reports everything else as a value.

Transport-layer handlers remain responsible for bounding batch size and adding
any IO-specific concurrency.
-}
checkMany ::
    (ConsistencyStore :> es, TupleStore :> es) =>
    ReachabilityGraph ->
    Consistency ->
    CaveatContext ->
    [BatchPair] ->
    Eff es [Either EnError CheckDecision]
checkMany graph consistency context pairs = do
    ResolvedConsistency{revision} <- resolveConsistency consistency
    (resultsByPair, _memo) <-
        foldM
            (evaluateDistinct revision)
            (Map.empty, Map.empty)
            (dedupePairs pairs)
    pure [Map.findWithDefault (Right Denied) pair resultsByPair | pair <- pairs]
  where
    evaluateDistinct revision (resultsByPair, memo) pair = do
        (result, memo') <-
            runCheckMemo graph context revision pair.subject pair.permission pair.object memo
        pure (Map.insert pair result resultsByPair, memo')

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

{- | Did a decision depend on cutting a cycle?

A cut answers "no members" for a subproblem the evaluator is already inside. That
answer is correct for the enclosing traversal and wrong for anyone else, so a
'Tainted' decision may be returned but never memoized or cached.
-}
data CutTaint
    = Untainted
    | Tainted
    deriving stock (Eq, Show)

instance Semigroup CutTaint where
    Untainted <> Untainted = Untainted
    _ <> _ = Tainted

instance Monoid CutTaint where
    mempty = Untainted

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
runCheckMemoWithCache cacheOps graph context revision subject permission object memo = do
    (result, memo', _taint) <- evalRelationMemo cacheOps graph context revision subject object permission initialState memo
    pure (result, memo')

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

{- | Evaluate @subject@'s membership in @object#relation@.

A revisited subproblem contributes no members. Zanzibar's semantics for a
membership recursion is its least fixpoint, and a cycle adds nothing to it, so
re-entering a subproblem the evaluator is already inside yields 'Denied' -- the
identity of 'Decision.union', which makes a cyclic branch simply drop out of a
union, and the absorbing element of intersection, which correctly denies. This is
what 'En.Lookup' already does on revisit.

That 'Denied' is true only /inside/ the current recursion stack: evaluated on its
own, the same subproblem may well be 'Allowed'. Any decision computed with the
help of such a cut is therefore stack-local and must not outlive the stack, so
this function reports whether its subtree consumed a cut, and refuses to write a
tainted decision into the within-call memo or the cross-request decision cache.
Without that, evaluating @Y@ where @X = Y union carol@ and @Y = X@ could memoize
@Y = Denied@ (cut at @X@) and hand that answer to a later pair of the same
'checkMany' batch, for which @Y@ is genuinely 'Allowed'.
-}
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
    Eff es (Either EnError CheckDecision, CheckMemo, CutTaint)
evalRelationMemo cacheOps graph context revision subject object relation state memo
    | state.depth >= maxDepth =
        pure (Left ResolutionLimitExceeded, memo, Untainted)
    | subproblem `elem` state.visited =
        pure (Right Denied, memo, Tainted)
    | otherwise =
        case Map.lookup key memo of
            Just decision ->
                pure (Right decision, memo, Untainted)
            Nothing -> do
                external <- lookupExternalDecision
                case external of
                    Just decision ->
                        pure (Right decision, Map.insert key decision memo, Untainted)
                    Nothing ->
                        case Map.lookup ref graph.relations of
                            Nothing ->
                                pure (Left (UnknownRelation (renderRef ref)), memo, Untainted)
                            Just schemaRelation -> do
                                (result, memo', taint) <-
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
                                case (result, taint) of
                                    (Right decision, Untainted) -> do
                                        insertExternalDecision decision
                                        pure (result, Map.insert key decision memo', Untainted)
                                    _ ->
                                        pure (result, memo', taint)
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
    Eff es (Either EnError CheckDecision, CheckMemo, CutTaint)
evalRewriteMemo cacheOps graph context revision subject object currentRelation rewrite state memo =
    case rewrite of
        This ->
            evalThisMemo cacheOps graph context revision subject object currentRelation state memo
        ComputedUserset relation ->
            evalRelationMemo cacheOps graph context revision subject object relation state memo
        TupleToUserset tuplesetRelation computedRelation ->
            evalTupleToUsersetMemo cacheOps graph context revision subject object tuplesetRelation computedRelation state memo
        Union rewrites ->
            evalBranchesMemo Decision.union unionSettled cacheOps graph context revision subject object currentRelation rewrites state memo
        Intersection rewrites ->
            evalBranchesMemo Decision.intersection intersectionSettled cacheOps graph context revision subject object currentRelation rewrites state memo
        Exclusion base subtractRewrite -> do
            (baseDecision, memo', baseTaint) <- evalRewriteMemo cacheOps graph context revision subject object currentRelation base state memo
            case baseDecision of
                Left err -> pure (Left err, memo', baseTaint)
                -- Nothing can be subtracted from nothing, so the subtrahend is
                -- never evaluated. Every other base must consult it: an
                -- unconditional subtraction denies even a conditional base.
                Right Denied -> pure (Right Denied, memo', baseTaint)
                Right base' -> do
                    (subtractDecision, memo'', subtractTaint) <- evalRewriteMemo cacheOps graph context revision subject object currentRelation subtractRewrite state memo'
                    pure (Decision.exclusionDecisions base' <$> subtractDecision, memo'', baseTaint <> subtractTaint)
        Caveated caveat rewriteInner -> do
            (inner, memo', taint) <- evalRewriteMemo cacheOps graph context revision subject object currentRelation rewriteInner state memo
            pure (applyRewriteCaveat graph context caveat =<< inner, memo', taint)

{- | A branch decision that settles its combinator, letting the rest go unevaluated.

'Allowed' absorbs a union and 'Denied' absorbs an intersection, so once one
appears no later branch can change the answer -- see 'Decision.unionDecisions'
and 'Decision.intersectionDecisions'. A conditional branch settles neither, since
its obligations must still be merged with whatever follows.
-}
unionSettled :: CheckDecision -> Bool
unionSettled = (== Allowed)

intersectionSettled :: CheckDecision -> Bool
intersectionSettled = (== Denied)

{- | Evaluate branches left to right, stopping at the first that settles the
combinator, and combine what was evaluated with @combine@.

Skipping the remaining branches cannot change the answer: the settling value
absorbs them. It does change what /errors/ are observed — a malformed branch
after a settling one goes unseen — which is deliberate. A subject who provably
has access should not be denied an answer because an unrelated branch of the
same permission references a relation that no longer exists. An error before any
settling branch still fails the whole check: with cycles no longer erroring, a
'Left' here is a genuine failure (a store outage, an unknown relation) and
answering around it would turn outages into data-dependent decisions.
-}
evalBranchesMemo ::
    (TupleStore :> es) =>
    ([CheckDecision] -> CheckDecision) ->
    (CheckDecision -> Bool) ->
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
    Eff es (Either EnError CheckDecision, CheckMemo, CutTaint)
evalBranchesMemo combine settles cacheOps graph context revision subject object currentRelation rewrites state memo =
    go [] memo mempty rewrites
  where
    go acc currentMemo taint [] =
        pure (Right (combine (reverse acc)), currentMemo, taint)
    go acc currentMemo taint (rewrite : rest) = do
        (result, memo', branchTaint) <- evalRewriteMemo cacheOps graph context revision subject object currentRelation rewrite state currentMemo
        let taint' = taint <> branchTaint
        case result of
            Left err -> pure (Left err, memo', taint')
            Right decision
                | settles decision -> pure (Right decision, memo', taint')
                | otherwise -> go (decision : acc) memo' taint' rest

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
    Eff es (Either EnError CheckDecision, CheckMemo, CutTaint)

{- | Evaluate the directly-stored tuples of @object#relation@.

Probe first: ask the store for just the rows granting @relation@ to @subject@ or
to @subject@'s type wildcard. An uncaveated hit proves access, and 'Decision.union'
returns 'Allowed' whenever any branch is 'Allowed', so nothing further can change
the answer -- return immediately without reading the relation at all. This is what
makes a check on a relation of any width cost one bounded store read.

If the probe cannot settle it, enumerate the relation to find nested groups. Only
subject-set rows are worth recursing into: the probe has already answered exactly
for concrete and wildcard subjects, so every other row contributes 'Denied', which
is the identity of union. Rows the probe already matched are skipped here so they
are not counted twice.

Enumeration drains pages rather than demanding the relation fit in one. A relation
wider than a page is a large group, not a resolution failure.

Before recursing into the nested groups one at a time, ask the store once per
(group type, group relation) which of them contain the subject directly. One
batched reverse query replaces one recursive descent per group, which is the
difference between twenty store reads and three when an object is shared with
twenty teams.
-}
evalThisMemo cacheOps graph context revision subject object relation state memo
    | state.depth >= maxDepth =
        pure (Left ResolutionLimitExceeded, memo, Untainted)
    | otherwise = do
        probedRows <- probeTuples revision object relation candidates
        let probeDecisions =
                [applyTupleCaveat graph context tuple.caveat Allowed | TupleRow{tuple} <- probedRows]
        if Right Allowed `elem` probeDecisions
            then pure (Right Allowed, memo, Untainted)
            else do
                rows <- drainObjectRelation revision object relation
                let usersetRows = filter recursable rows
                proven <- provenByDirectGroupMembership usersetRows
                if proven
                    then pure (Right Allowed, memo, Untainted)
                    else do
                        (recursedDecisions, memo', taint) <- foldM rowDecision ([], memo, mempty) usersetRows
                        pure (Decision.union <$> sequence (probeDecisions <> recursedDecisions), memo', taint)
  where
    candidates = subjectsWithWildcard subject

    -- The probe answered for these; recursing would double-count them.
    recursable TupleRow{tuple} =
        case tuple.subject of
            SubjectSet _ _ -> tuple.subject `notElem` candidates
            SubjectId _ -> False
            SubjectWildcard _ -> False

    {- A row the batched query may settle. Every condition is load-bearing:
    the attachment edge must grant unconditionally (otherwise its caveat gates
    the answer and only recursion composes the gates correctly); the group's
    relation must union in its own stored tuples (a relation defined as, say,
    @Intersection [This, other]@ is not satisfied by a stored tuple alone); and
    the descent must be one the recursive path would actually have taken, so a
    subproblem barred by the cycle or depth guard is left to recursion to
    reject exactly as before. -}
    acceleratable row@TupleRow{tuple} =
        case tuple.subject of
            SubjectSet groupObject groupRelation ->
                recursable row
                    && applyTupleCaveat graph context tuple.caveat Allowed == Right Allowed
                    && relationUnionsThis graph groupObject.objectType groupRelation
                    && state.depth < maxDepth
                    && Subproblem{subject, object = groupObject, relation = groupRelation} `notElem` state.visited
            _ -> False

    {- One reverse query per (group type, group relation) bucket answers "which
    of these groups contain the subject directly?". A hit on an uncaveated
    membership edge, under an uncaveated attachment edge, proves Allowed for the
    whole relation. A miss proves nothing -- the group may still grant access
    through its own rewrite -- so evaluation falls back to recursion. The query
    can therefore only find an answer earlier, never change one. -}
    provenByDirectGroupMembership rows
        | null targets = pure False
        | otherwise = or <$> traverse confirmBucket (Map.toList buckets)
      where
        targets =
            [ (groupObject, groupRelation)
            | row@TupleRow{tuple} <- rows
            , acceleratable row
            , SubjectSet groupObject groupRelation <- [tuple.subject]
            ]
        buckets =
            Map.fromListWith
                (<>)
                [((groupObject.objectType, groupRelation), [groupObject]) | (groupObject, groupRelation) <- targets]

    confirmBucket ((groupType, groupRelation), groupObjects) = do
        rows <- drainStartingWithUser revision groupType groupRelation candidates
        pure (any grantsDirectly rows)
      where
        grantsDirectly TupleRow{tuple} =
            tuple.object `elem` groupObjects
                && applyTupleCaveat graph context tuple.caveat Allowed == Right Allowed

    rowDecision (decisions, memo', taint) TupleRow{tuple} =
        case tuple.subject of
            SubjectSet subjectObject subjectRelation -> do
                (decision, memo'', rowTaint) <- evalRelationMemo cacheOps graph context revision subject subjectObject subjectRelation state memo'
                pure (decisions <> [decision >>= applyTupleCaveat graph context tuple.caveat], memo'', taint <> rowTaint)
            _ ->
                pure (decisions, memo', taint)

{- | Does @objectType#relation@ union in its directly-stored tuples?

Only then does a stored membership tuple by itself prove the relation holds. A
relation whose rewrite is an intersection, an exclusion, or an arrow may ignore
its own stored tuples, or subtract from them.
-}
relationUnionsThis :: ReachabilityGraph -> ObjectType -> RelationName -> Bool
relationUnionsThis graph objectType relation =
    case Map.lookup RelationRef{objectType, relation} graph.relations of
        Nothing -> False
        Just schemaRelation -> unionsThis schemaRelation.rewrite
  where
    unionsThis = \case
        This -> True
        Union rewrites -> any unionsThis rewrites
        _ -> False

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
    Eff es (Either EnError CheckDecision, CheckMemo, CutTaint)
evalTupleToUsersetMemo cacheOps graph context revision subject object tuplesetRelation computedRelation state memo = do
    rows <- drainObjectRelation revision object tuplesetRelation
    (decisions, memo', taint) <- foldM rowDecision ([], memo, mempty) rows
    pure (Decision.union <$> sequence decisions, memo', taint)
  where
    rowDecision (decisions, memo', taint) TupleRow{tuple} =
        case tuple.subject of
            SubjectId subjectObject -> do
                (decision, memo'', rowTaint) <- evalRelationMemo cacheOps graph context revision subject subjectObject computedRelation state memo'
                pure (decisions <> [applyRowGate tuple decision], memo'', taint <> rowTaint)
            SubjectSet subjectObject subjectRelation -> do
                (decision, memo'', rowTaint) <- evalRelationMemo cacheOps graph context revision subject subjectObject subjectRelation state memo'
                pure (decisions <> [applyRowGate tuple decision], memo'', taint <> rowTaint)
            SubjectWildcard _ ->
                pure (decisions <> [Right Denied], memo', taint)

    applyRowGate tuple =
        (>>= applyTupleCaveat graph context tuple.caveat)

{- | The subjects a stored row may name to grant @subject@ directly: the subject
itself, and -- for a concrete subject -- the wildcard over its object type,
which means "every object of this type". Mirrors 'En.Lookup.subjectsWithWildcard'.
-}
subjectsWithWildcard :: Subject -> [Subject]
subjectsWithWildcard subject =
    subject
        : case subject of
            SubjectId object -> [SubjectWildcard object.objectType]
            SubjectSet _ _ -> []
            SubjectWildcard _ -> []

{- | Read every row of @object#relation@, following page cursors to the end.

'pageLimit' is a batch size here, not a ceiling: a relation with more rows than
one page is a large group, and asking whether someone belongs to it is a
question with an answer. Mirrors the drain loops in "En.Lookup" and "En.Expand".
-}
drainObjectRelation ::
    (TupleStore :> es) =>
    Revision ->
    ObjectRef ->
    RelationName ->
    Eff es [TupleRow]
drainObjectRelation revision object relation =
    drain Nothing []
  where
    drain cursor acc = do
        page <- readObjectRelation revision object relation pageLimit cursor
        let acc' = acc <> page.rows
        case page.state of
            Exhausted -> pure acc'
            HasMore next -> drain (Just next) acc'
            Truncated next -> drain (Just next) acc'

{- | Read every @objectType#relation@ row whose subject is one of @subjects@,
following page cursors to the end. This is Zanzibar's reverse query: rather than
asking each candidate group "do you contain the subject?", ask storage once for
all the groups of a type that do. Mirrors 'En.Lookup.readRowsForSubjects'.
-}
drainStartingWithUser ::
    (TupleStore :> es) =>
    Revision ->
    ObjectType ->
    RelationName ->
    [Subject] ->
    Eff es [TupleRow]
drainStartingWithUser _ _ _ [] =
    pure []
drainStartingWithUser revision objectType relation subjects =
    drain Nothing []
  where
    drain cursor acc = do
        page <-
            readStartingWithUser
                revision
                UsersetQuery
                    { queryType = objectType
                    , queryRelation = relation
                    , querySubjects = subjects
                    , queryLimit = pageLimit
                    , queryCursor = cursor
                    }
        let acc' = acc <> page.rows
        case page.state of
            Exhausted -> pure acc'
            HasMore next -> drain (Just next) acc'
            Truncated next -> drain (Just next) acc'

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
