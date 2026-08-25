-- | Forward evaluation: does a subject have a permission on an object?
module En.Check
  ( CheckDecision (..),
    CheckOutcome (..),
    BatchOutcome (..),
    CaveatObligation (..),
    BatchPair (..),
    CheckCacheEnv (..),
    CheckMemo,
    emptyCheckMemo,
    check,
    checkCached,
    checkMany,
    checkAtRevision,
    checkCachedAtRevision,
    checkWithBudget,
    checkCachedWithBudget,
    checkManyWithBudget,
    checkAtRevisionWithBudget,
    checkCachedAtRevisionWithBudget,
  )
where

import Control.Monad (foldM)
import Data.Map.Strict qualified as Map
import Data.Maybe (isNothing)
import Data.Set (Set)
import Data.Set qualified as Set
import Data.Text (Text)
import Effectful (Eff, IOE, liftIO, (:>))
import Effectful.Error.Static (Error, throwError)
import En.Budget (EvaluationBudget (..), defaultEvaluationBudget)
import En.Cache (Cache, SubproblemKey (..), insertCache, lookupCache)
import En.Caveat (applyResidual)
import En.Decision (CaveatObligation (..), CheckDecision (..), ResidualDecision (..))
import En.Decision qualified as Decision
import En.Effect.ConsistencyStore (ConsistencyStore, ResolvedConsistency (..), mintToken, resolveConsistency)
import En.Effect.TupleStore (PageState (..), TuplePage (..), TupleRow (..), TupleStore, UsersetQuery (..), probeTuples, readObjectRelation, readStartingWithUser)
import En.Error (EnError (..))
import En.Reachability (ReachabilityGraph (..), RelationRef (..))
import En.Revision (Consistency, ConsistencyToken, DatastoreId, Revision (..))
import En.Schema (CaveatName (..), ObjectType (..), Relation (..), RelationName (..), Rewrite (..))
import En.Tuple
  ( CaveatContext (..),
    CaveatPayload (..),
    ObjectRef (..),
    Subject (..),
    Tuple (..),
    TupleCaveat (..),
  )

-- | One (subject, permission, object) question in a batch.
--
-- A 'checkMany' call evaluates every pair against one resolved consistency
-- snapshot and one caveat context, returning decisions in input order.
data BatchPair = BatchPair
  { subject :: !Subject,
    permission :: !RelationName,
    object :: !ObjectRef
  }
  deriving stock (Eq, Ord, Show)

-- | A decision, and the snapshot it was decided at.
--
-- 'checkedAt' is a token pinning the revision 'resolveConsistency' chose for this
-- call. It is what a caller passes back as @AtLeastAsFresh@ to make a follow-up read
-- observe everything this one observed -- and it is what an 'En.Biscuit' grant needs
-- to record the snapshot a decision was made at. Without it a decision is an answer
-- to a question about a moment the caller cannot name.
data CheckOutcome = CheckOutcome
  { decision :: !CheckDecision,
    checkedAt :: !ConsistencyToken
  }
  deriving stock (Eq, Show)

-- | A batch's decisions, and the one snapshot all of them were decided at.
--
-- One token, not one per pair: 'checkMany' resolves consistency once and evaluates
-- every pair against that revision, so per-pair tokens would be copies of each other.
--
-- Each decision is an 'Either' because a pair that fails to evaluate does not fail
-- the batch -- see 'checkMany'.
data BatchOutcome = BatchOutcome
  { decisions :: ![Either EnError CheckDecision],
    checkedAt :: !ConsistencyToken
  }
  deriving stock (Eq, Show)

data CheckCacheEnv = CheckCacheEnv
  { cacheDatastoreId :: !DatastoreId,
    cacheDecisions :: !(Cache SubproblemKey ResidualDecision)
  }

-- | Does @subject@ have @permission@ on @object@? Forward evaluation over the
-- reachability graph and the tuple store.
--
-- Evaluation is /symbolic/: the traversal never looks at the request's caveat
-- context. Every subproblem yields a 'ResidualDecision' -- the answer with its
-- caveats left as named, unevaluated gates -- and the context is folded in exactly
-- once, here at the top, by 'applyResidual'. See 'evalRelationMemo' for why that
-- matters.
check ::
  (ConsistencyStore :> es, TupleStore :> es, Error EnError :> es) =>
  ReachabilityGraph ->
  Consistency ->
  CaveatContext ->
  Subject ->
  RelationName ->
  ObjectRef ->
  Eff es CheckOutcome
check =
  checkWithBudget defaultEvaluationBudget

-- | 'check' under caller-chosen evaluation bounds. See "En.Budget".
checkWithBudget ::
  (ConsistencyStore :> es, TupleStore :> es, Error EnError :> es) =>
  EvaluationBudget ->
  ReachabilityGraph ->
  Consistency ->
  CaveatContext ->
  Subject ->
  RelationName ->
  ObjectRef ->
  Eff es CheckOutcome
checkWithBudget budget graph consistency context subject permission object = do
  ResolvedConsistency {revision} <- resolveConsistency consistency
  checkedAt <- mintToken revision
  (residual, _memo) <- runCheckMemo budget graph revision subject permission object Map.empty
  decision <- either throwError pure (residual >>= applyResidual graph.caveats context)
  pure CheckOutcome {decision, checkedAt}

-- | Cached variant of 'check'. Cache hits are keyed by datastore id, schema
-- hash, resolved revision, subject, relation, and object -- deliberately /not/ by
-- the request's caveat context.
--
-- What the cache stores is a 'ResidualDecision': the fully-traversed answer with
-- its caveats still symbolic. Two requests that differ only in @current_time@ ask
-- the same question and share one entry, and each still gets its own correct
-- answer, because the caveats are re-evaluated against each request's own context
-- on the way out. A caveated decision can never be served with a stale context, by
-- construction: no context ever entered the cache.
checkCached ::
  (ConsistencyStore :> es, TupleStore :> es, IOE :> es, Error EnError :> es) =>
  CheckCacheEnv ->
  ReachabilityGraph ->
  Consistency ->
  CaveatContext ->
  Subject ->
  RelationName ->
  ObjectRef ->
  Eff es CheckOutcome
checkCached =
  checkCachedWithBudget defaultEvaluationBudget

-- | 'checkCached' under caller-chosen evaluation bounds. See "En.Budget".
checkCachedWithBudget ::
  (ConsistencyStore :> es, TupleStore :> es, IOE :> es, Error EnError :> es) =>
  EvaluationBudget ->
  CheckCacheEnv ->
  ReachabilityGraph ->
  Consistency ->
  CaveatContext ->
  Subject ->
  RelationName ->
  ObjectRef ->
  Eff es CheckOutcome
checkCachedWithBudget budget cacheEnv graph consistency context subject permission object = do
  ResolvedConsistency {revision} <- resolveConsistency consistency
  checkedAt <- mintToken revision
  (residual, _memo) <- runCheckMemoWithCache budget (Just (decisionCacheOps cacheEnv graph)) graph revision subject permission object Map.empty
  decision <- either throwError pure (residual >>= applyResidual graph.caveats context)
  pure CheckOutcome {decision, checkedAt}

-- | Evaluate many checks against one resolved consistency snapshot.
--
-- The engine resolves consistency once, evaluates distinct pairs sequentially
-- through a within-call memo, and returns one result per input pair, in input
-- order.
--
-- The two ways a batch can fail are kept apart. Resolving consistency is a
-- request-level step: if it fails, no pair has an answer, and the failure escapes
-- through whatever error effect the 'ConsistencyStore' interpreter raises, aborting
-- the batch. Evaluating a pair is pair-level: its failure is returned as a 'Left'
-- beside the pairs that succeeded, so a caller can tell "denied" from "this one
-- broke" and decide what to do. The engine deliberately does not decide for them; a
-- transport that must answer with a decision should fail closed and report 'Denied'.
--
-- This function therefore needs no @Error EnError@ capability of its own -- it
-- raises nothing that is not already raised by the interpreters it runs under, and
-- reports everything else as a value.
--
-- The 'BatchOutcome' carries one 'BatchOutcome.checkedAt' token for the whole batch,
-- because the whole batch was decided at one revision.
--
-- The within-call memo holds 'ResidualDecision's, which carry no caveat context, so
-- sharing them between the pairs of one batch is safe for the same reason sharing
-- them between requests is: the context is applied per pair, after the traversal.
-- The memo is nonetheless discarded when the batch ends, because it may hold
-- answers that are only true within this call -- see 'evalRelationMemo' on cut
-- taint.
--
-- Transport-layer handlers remain responsible for bounding batch size and adding
-- any IO-specific concurrency.
checkMany ::
  (ConsistencyStore :> es, TupleStore :> es) =>
  ReachabilityGraph ->
  Consistency ->
  CaveatContext ->
  [BatchPair] ->
  Eff es BatchOutcome
checkMany =
  checkManyWithBudget defaultEvaluationBudget

-- | 'checkMany' under caller-chosen evaluation bounds. See "En.Budget".
checkManyWithBudget ::
  (ConsistencyStore :> es, TupleStore :> es) =>
  EvaluationBudget ->
  ReachabilityGraph ->
  Consistency ->
  CaveatContext ->
  [BatchPair] ->
  Eff es BatchOutcome
checkManyWithBudget budget graph consistency context pairs = do
  ResolvedConsistency {revision} <- resolveConsistency consistency
  checkedAt <- mintToken revision
  (residualsByPair, _memo) <-
    foldM
      (evaluateDistinct revision)
      (Map.empty, Map.empty)
      (dedupePairs pairs)
  pure
    BatchOutcome
      { decisions =
          [ Map.findWithDefault (Right RDenied) pair residualsByPair >>= applyResidual graph.caveats context
          | pair <- pairs
          ],
        checkedAt
      }
  where
    evaluateDistinct revision (residualsByPair, memo) pair = do
      (residual, memo') <-
        runCheckMemo budget graph revision pair.subject pair.permission pair.object memo
      pure (Map.insert pair residual residualsByPair, memo')

-- | Engine-internal: check at an already-resolved revision, threading a
-- caller-owned memo.
--
-- "En.Lookup" needs this. Its reach-then-check confirms each candidate with a
-- forward check, and calling the public 'check' would re-resolve the caller's
-- 'Consistency' once per candidate -- so under @MinimizeLatency@ or
-- @FullyConsistent@ a confirmation could read a /different snapshot/ than the
-- traversal that produced the candidate it is confirming. Taking the revision as an
-- argument makes one lookup read one snapshot.
--
-- The memo is threaded rather than rebuilt so a batch of confirmations shares
-- subproblems: confirming twenty objects that all descend from the same group reads
-- that group once. The memo holds 'ResidualDecision's, which mention no caveat
-- context, so sharing one across confirmations is sound even if the answers differ
-- per context -- the context is applied here, at the boundary, per candidate.
--
-- Callers must not carry a memo across a revision boundary. This function cannot
-- check that for them, which is why it is engine-internal rather than public.
checkAtRevision ::
  (TupleStore :> es) =>
  ReachabilityGraph ->
  CaveatContext ->
  Revision ->
  Subject ->
  RelationName ->
  ObjectRef ->
  CheckMemo ->
  Eff es (Either EnError CheckDecision, CheckMemo)
checkAtRevision =
  checkAtRevisionWithBudget defaultEvaluationBudget

-- | 'checkAtRevision' under caller-chosen evaluation bounds. See "En.Budget".
checkAtRevisionWithBudget ::
  (TupleStore :> es) =>
  EvaluationBudget ->
  ReachabilityGraph ->
  CaveatContext ->
  Revision ->
  Subject ->
  RelationName ->
  ObjectRef ->
  CheckMemo ->
  Eff es (Either EnError CheckDecision, CheckMemo)
checkAtRevisionWithBudget budget graph context revision subject permission object memo = do
  (residual, memo') <- runCheckMemo budget graph revision subject permission object memo
  pure (residual >>= applyResidual graph.caveats context, memo')

-- | 'checkAtRevision' against the cross-request decision cache. See 'checkCached'
-- for what that cache stores and why a caveat context never enters it.
checkCachedAtRevision ::
  (TupleStore :> es, IOE :> es) =>
  CheckCacheEnv ->
  ReachabilityGraph ->
  CaveatContext ->
  Revision ->
  Subject ->
  RelationName ->
  ObjectRef ->
  CheckMemo ->
  Eff es (Either EnError CheckDecision, CheckMemo)
checkCachedAtRevision =
  checkCachedAtRevisionWithBudget defaultEvaluationBudget

-- | 'checkCachedAtRevision' under caller-chosen evaluation bounds. See "En.Budget".
checkCachedAtRevisionWithBudget ::
  (TupleStore :> es, IOE :> es) =>
  EvaluationBudget ->
  CheckCacheEnv ->
  ReachabilityGraph ->
  CaveatContext ->
  Revision ->
  Subject ->
  RelationName ->
  ObjectRef ->
  CheckMemo ->
  Eff es (Either EnError CheckDecision, CheckMemo)
checkCachedAtRevisionWithBudget budget cacheEnv graph context revision subject permission object memo = do
  (residual, memo') <- runCheckMemoWithCache budget (Just (decisionCacheOps cacheEnv graph)) graph revision subject permission object memo
  pure (residual >>= applyResidual graph.caveats context, memo')

-- | A memo with nothing in it, for the first check of a batch.
emptyCheckMemo :: CheckMemo
emptyCheckMemo =
  Map.empty

dedupePairs :: [BatchPair] -> [BatchPair]
dedupePairs =
  reverse . fst . foldl' step ([], Map.empty)
  where
    step (ordered, seen) pair
      | Map.member pair seen = (ordered, seen)
      | otherwise = (pair : ordered, Map.insert pair () seen)

data EvalState = EvalState
  { depth :: !Int,
    visited :: !(Set Subproblem),
    budget :: !EvaluationBudget
  }

data Subproblem = Subproblem
  { subject :: !Subject,
    object :: !ObjectRef,
    relation :: !RelationName
  }
  deriving stock (Eq, Ord, Show)

data MemoKey = MemoKey
  { revision :: !Text,
    subproblem :: !Subproblem
  }
  deriving stock (Eq, Ord, Show)

type CheckMemo = Map.Map MemoKey ResidualDecision

-- | Did a decision depend on cutting a cycle?
--
-- A cut answers "no members" for a subproblem the evaluator is already inside. That
-- answer is correct for the enclosing traversal and wrong for anyone else, so a
-- 'Tainted' decision may be returned but never memoized or cached.
data CutTaint
  = Untainted
  | Tainted
  deriving stock (Eq, Show)

instance Semigroup CutTaint where
  Untainted <> Untainted = Untainted
  _ <> _ = Tainted

instance Monoid CutTaint where
  mempty = Untainted

initialState :: EvaluationBudget -> EvalState
initialState budget =
  EvalState {depth = 0, visited = Set.empty, budget}

runCheckMemo ::
  (TupleStore :> es) =>
  EvaluationBudget ->
  ReachabilityGraph ->
  Revision ->
  Subject ->
  RelationName ->
  ObjectRef ->
  CheckMemo ->
  Eff es (Either EnError ResidualDecision, CheckMemo)
runCheckMemo budget =
  runCheckMemoWithCache budget Nothing

runCheckMemoWithCache ::
  (TupleStore :> es) =>
  EvaluationBudget ->
  Maybe (DecisionCacheOps es) ->
  ReachabilityGraph ->
  Revision ->
  Subject ->
  RelationName ->
  ObjectRef ->
  CheckMemo ->
  Eff es (Either EnError ResidualDecision, CheckMemo)
runCheckMemoWithCache budget cacheOps graph revision subject permission object memo = do
  (residual, memo', _taint) <- evalRelationMemo cacheOps graph revision subject object permission (initialState budget) memo
  pure (residual, memo')

data DecisionCacheOps es = DecisionCacheOps
  { lookupDecision :: !(Revision -> Subject -> RelationName -> ObjectRef -> Eff es (Maybe ResidualDecision)),
    insertDecision :: !(Revision -> Subject -> RelationName -> ObjectRef -> ResidualDecision -> Eff es ())
  }

-- | The cross-request decision cache, as the evaluator sees it.
--
-- Note the absence of a 'CaveatContext' parameter. Keys and values are both
-- context-free, which is the whole point: a residual computed for one request
-- answers every other request that asks the same question.
decisionCacheOps ::
  (IOE :> es) =>
  CheckCacheEnv ->
  ReachabilityGraph ->
  DecisionCacheOps es
decisionCacheOps CheckCacheEnv {cacheDatastoreId, cacheDecisions} graph =
  DecisionCacheOps
    { lookupDecision = \revision subject relation object ->
        liftIO (lookupCache cacheDecisions (cacheKey revision subject relation object)),
      insertDecision = \revision subject relation object residual ->
        liftIO (insertCache cacheDecisions (cacheKey revision subject relation object) residual)
    }
  where
    cacheKey revision subject relation object =
      SubproblemKey
        { datastoreId = cacheDatastoreId,
          schemaHash = graph.hash,
          revision,
          subject,
          relation,
          object
        }

-- | Evaluate @subject@'s membership in @object#relation@, as a residual.
--
-- The result is a 'ResidualDecision': 'RAllowed', 'RDenied', or a tree of named
-- caveats joined by the same union\/intersection\/exclusion structure the traversal
-- found. No request context is consulted anywhere below this point. That is what
-- lets the within-call memo and the cross-request decision cache both store the
-- same value and share it between requests whose contexts differ; the caller folds
-- its own context in afterwards with 'applyResidual'.
--
-- A revisited subproblem contributes no members. Zanzibar's semantics for a
-- membership recursion is its least fixpoint, and a cycle adds nothing to it, so
-- re-entering a subproblem the evaluator is already inside yields 'RDenied' -- the
-- identity of 'Decision.rUnion', which makes a cyclic branch simply drop out of a
-- union, and the absorbing element of intersection, which correctly denies. This is
-- what "En.Lookup" already does on revisit.
--
-- That 'RDenied' is true only /inside/ the current recursion stack: evaluated on its
-- own, the same subproblem may well be allowed. Any decision computed with the
-- help of such a cut is therefore stack-local and must not outlive the stack, so
-- this function reports whether its subtree consumed a cut, and refuses to write a
-- tainted residual into the within-call memo or the cross-request decision cache.
-- Without that, evaluating @Y@ where @X = Y union carol@ and @Y = X@ could memoize
-- @Y = RDenied@ (cut at @X@) and hand that answer to a later pair of the same
-- 'checkMany' batch, for which @Y@ is genuinely allowed. Making the residual
-- context-free does not weaken this: a context-free decision derived under a cut is
-- no safer to cache than a context-bearing one.
evalRelationMemo ::
  (TupleStore :> es) =>
  Maybe (DecisionCacheOps es) ->
  ReachabilityGraph ->
  Revision ->
  Subject ->
  ObjectRef ->
  RelationName ->
  EvalState ->
  CheckMemo ->
  Eff es (Either EnError ResidualDecision, CheckMemo, CutTaint)
evalRelationMemo cacheOps graph revision subject object relation state memo
  | state.depth >= state.budget.maxDepth =
      pure (Left ResolutionLimitExceeded, memo, Untainted)
  | Set.member subproblem state.visited =
      pure (Right RDenied, memo, Tainted)
  | otherwise =
      case Map.lookup key memo of
        Just residual ->
          pure (Right residual, memo, Untainted)
        Nothing -> do
          external <- lookupExternalDecision
          case external of
            Just residual ->
              pure (Right residual, Map.insert key residual memo, Untainted)
            Nothing ->
              case Map.lookup ref graph.relations of
                Nothing ->
                  pure (Left (UnknownRelation (renderRef ref)), memo, Untainted)
                Just schemaRelation -> do
                  (result, memo', taint) <-
                    evalRewriteMemo
                      cacheOps
                      graph
                      revision
                      subject
                      object
                      relation
                      schemaRelation.rewrite
                      state {depth = state.depth + 1, visited = Set.insert subproblem state.visited}
                      memo
                  case (result, taint) of
                    (Right residual, Untainted) -> do
                      insertExternalDecision residual
                      pure (result, Map.insert key residual memo', Untainted)
                    _ ->
                      pure (result, memo', taint)
  where
    ref = RelationRef {objectType = object.objectType, relation}
    subproblem = Subproblem {subject, object, relation}
    key = MemoKey revision.revisionEncoding subproblem
    lookupExternalDecision =
      case cacheOps of
        Nothing -> pure Nothing
        Just ops -> ops.lookupDecision revision subject relation object
    insertExternalDecision residual =
      case cacheOps of
        Nothing -> pure ()
        Just ops -> ops.insertDecision revision subject relation object residual

evalRewriteMemo ::
  (TupleStore :> es) =>
  Maybe (DecisionCacheOps es) ->
  ReachabilityGraph ->
  Revision ->
  Subject ->
  ObjectRef ->
  RelationName ->
  Rewrite ->
  EvalState ->
  CheckMemo ->
  Eff es (Either EnError ResidualDecision, CheckMemo, CutTaint)
evalRewriteMemo cacheOps graph revision subject object currentRelation rewrite state memo =
  case rewrite of
    This ->
      evalThisMemo cacheOps graph revision subject object currentRelation state memo
    ComputedUserset relation ->
      evalRelationMemo cacheOps graph revision subject object relation state memo
    TupleToUserset tuplesetRelation computedRelation ->
      evalTupleToUsersetMemo cacheOps graph revision subject object tuplesetRelation computedRelation state memo
    Union rewrites ->
      evalBranchesMemo Decision.rUnion unionSettled cacheOps graph revision subject object currentRelation rewrites state memo
    Intersection rewrites ->
      evalBranchesMemo Decision.rIntersection intersectionSettled cacheOps graph revision subject object currentRelation rewrites state memo
    Exclusion base subtractRewrite -> do
      (baseResidual, memo', baseTaint) <- evalRewriteMemo cacheOps graph revision subject object currentRelation base state memo
      case baseResidual of
        Left err -> pure (Left err, memo', baseTaint)
        -- Nothing can be subtracted from nothing, so the subtrahend is
        -- never evaluated. Every other base must consult it: an
        -- unconditional subtraction denies even a caveated base.
        --
        -- "Every other base" now includes a base whose caveats /would/
        -- deny under this request's context, which the traversal can no
        -- longer see. Evaluating the subtrahend anyway costs store reads
        -- but cannot change the answer: 'Decision.rExclusion' keeps the
        -- pair symbolic and 'applyResidual' lands on 'Denied' via
        -- 'Decision.exclusionDecisions', whose base-'Denied' row ignores
        -- the subtrahend entirely.
        Right RDenied -> pure (Right RDenied, memo', baseTaint)
        Right base' -> do
          (subtractResidual, memo'', subtractTaint) <- evalRewriteMemo cacheOps graph revision subject object currentRelation subtractRewrite state memo'
          pure (Decision.rExclusion base' <$> subtractResidual, memo'', baseTaint <> subtractTaint)
    Caveated caveat rewriteInner -> do
      (inner, memo', taint) <- evalRewriteMemo cacheOps graph revision subject object currentRelation rewriteInner state memo
      pure (residualGate graph (Just (rewriteCaveat caveat)) =<< inner, memo', taint)

-- | A rewrite-level @Caveated@ node gates on a caveat with no stored arguments:
-- everything it needs comes from the request context. Modelling it as a tuple
-- caveat with the empty payload keeps one gating path in this module.
rewriteCaveat :: CaveatName -> TupleCaveat
rewriteCaveat name =
  TupleCaveat {name, payload = CaveatPayload Map.empty}

-- | A branch residual that settles its combinator, letting the rest go unevaluated.
--
-- 'RAllowed' absorbs a union and 'RDenied' absorbs an intersection, so once one
-- appears no later branch can change the answer -- see 'Decision.rUnion' and
-- 'Decision.rIntersection'.
--
-- Only an /unconditional/ 'RAllowed' settles a union. A caveated allow is an
-- 'RCaveat', which settles nothing, because whether it allows at all depends on a
-- request context the traversal cannot see. This is exactly the property that keeps
-- the short-circuit sound once evaluation is symbolic: under the old inline
-- evaluator a satisfied caveat looked like 'Allowed' and absorbed the union, which
-- would be wrong to cache and replay against a request whose context fails that
-- same caveat.
unionSettled :: ResidualDecision -> Bool
unionSettled = (== RAllowed)

intersectionSettled :: ResidualDecision -> Bool
intersectionSettled = (== RDenied)

-- | Evaluate branches left to right, stopping at the first that settles the
-- combinator, and combine what was evaluated with @combine@.
--
-- Skipping the remaining branches cannot change the answer: the settling value
-- absorbs them. It does change what /errors/ are observed — a malformed branch
-- after a settling one goes unseen — which is deliberate. A subject who provably
-- has access should not be denied an answer because an unrelated branch of the
-- same permission references a relation that no longer exists. An error before any
-- settling branch still fails the whole check: with cycles no longer erroring, a
-- 'Left' here is a genuine failure (a store outage, an unknown relation) and
-- answering around it would turn outages into data-dependent decisions.
evalBranchesMemo ::
  (TupleStore :> es) =>
  ([ResidualDecision] -> ResidualDecision) ->
  (ResidualDecision -> Bool) ->
  Maybe (DecisionCacheOps es) ->
  ReachabilityGraph ->
  Revision ->
  Subject ->
  ObjectRef ->
  RelationName ->
  [Rewrite] ->
  EvalState ->
  CheckMemo ->
  Eff es (Either EnError ResidualDecision, CheckMemo, CutTaint)
evalBranchesMemo combine settles cacheOps graph revision subject object currentRelation rewrites state memo =
  go [] memo mempty rewrites
  where
    go acc currentMemo taint [] =
      pure (Right (combine (reverse acc)), currentMemo, taint)
    go acc currentMemo taint (rewrite : rest) = do
      (result, memo', branchTaint) <- evalRewriteMemo cacheOps graph revision subject object currentRelation rewrite state currentMemo
      let taint' = taint <> branchTaint
      case result of
        Left err -> pure (Left err, memo', taint')
        Right residual
          | settles residual -> pure (Right residual, memo', taint')
          | otherwise -> go (residual : acc) memo' taint' rest

evalThisMemo ::
  (TupleStore :> es) =>
  Maybe (DecisionCacheOps es) ->
  ReachabilityGraph ->
  Revision ->
  Subject ->
  ObjectRef ->
  RelationName ->
  EvalState ->
  CheckMemo ->
  Eff es (Either EnError ResidualDecision, CheckMemo, CutTaint)

-- | Evaluate the directly-stored tuples of @object#relation@.
--
-- Probe first: ask the store for just the rows granting @relation@ to @subject@ or
-- to @subject@'s type wildcard. An /uncaveated/ hit proves access, and
-- 'Decision.rUnion' returns 'RAllowed' whenever any branch is 'RAllowed', so nothing
-- further can change the answer -- return immediately without reading the relation at
-- all. This is what makes a check on a relation of any width cost one bounded store
-- read.
--
-- A /caveated/ probe hit no longer short-circuits, because the traversal cannot see
-- the request context and so cannot know the caveat passes. It becomes an 'RCaveat'
-- leaf and the relation is enumerated as usual. The answer is unchanged; the cost is
-- that a caveated direct grant reads more than a bare one.
--
-- If the probe cannot settle it, enumerate the relation to find nested groups. Only
-- subject-set rows are worth recursing into: the probe has already answered exactly
-- for concrete and wildcard subjects, so every other row contributes 'RDenied', which
-- is the identity of union. Rows the probe already matched are skipped here so they
-- are not counted twice.
--
-- Enumeration drains pages rather than demanding the relation fit in one. A relation
-- wider than a page is a large group, not a resolution failure.
--
-- Before recursing into the nested groups one at a time, ask the store once per
-- (group type, group relation) which of them contain the subject directly. One
-- batched reverse query replaces one recursive descent per group, which is the
-- difference between twenty store reads and three when an object is shared with
-- twenty teams.
evalThisMemo cacheOps graph revision subject object relation state memo
  | state.depth >= state.budget.maxDepth =
      pure (Left ResolutionLimitExceeded, memo, Untainted)
  | otherwise = do
      probedRows <- probeTuples revision object relation candidates
      let probeResiduals =
            [residualGate graph tuple.caveat RAllowed | TupleRow {tuple} <- probedRows]
      if Right RAllowed `elem` probeResiduals
        then pure (Right RAllowed, memo, Untainted)
        else do
          rows <- drainObjectRelation state.budget.pageLimit revision object relation
          let usersetRows = filter recursable rows
          proven <- provenByDirectGroupMembership usersetRows
          if proven
            then pure (Right RAllowed, memo, Untainted)
            else do
              (recursedResiduals, memo', taint) <- foldM rowResidual ([], memo, mempty) usersetRows
              pure (Decision.rUnion <$> sequence (probeResiduals <> reverse recursedResiduals), memo', taint)
  where
    candidates = subjectsWithWildcard subject

    -- The probe answered for these; recursing would double-count them.
    recursable TupleRow {tuple} =
      case tuple.subject of
        SubjectSet _ _ -> tuple.subject `notElem` candidates
        SubjectId _ -> False
        SubjectWildcard _ -> False

    {- A row the batched query may settle. Every condition is load-bearing:
    the attachment edge must be uncaveated (a caveat gates the answer, and only
    recursion composes the gates into the residual correctly -- the old inline
    evaluator could ask whether the caveat passed under the request context,
    which a symbolic traversal cannot); the group's relation must union in its
    own stored tuples (a relation defined as, say, @Intersection [This, other]@
    is not satisfied by a stored tuple alone); and the descent must be one the
    recursive path would actually have taken, so a subproblem barred by the cycle
    or depth guard is left to recursion to reject exactly as before. -}
    acceleratable row@TupleRow {tuple} =
      case tuple.subject of
        SubjectSet groupObject groupRelation ->
          recursable row
            && isNothing tuple.caveat
            && relationUnionsThis graph groupObject.objectType groupRelation
            && state.depth < state.budget.maxDepth
            && Set.notMember Subproblem {subject, object = groupObject, relation = groupRelation} state.visited
        _ -> False

    {- One reverse query per (group type, group relation) bucket answers "which
    of these groups contain the subject directly?". A hit on an uncaveated
    membership edge, under an uncaveated attachment edge, proves 'RAllowed' for
    the whole relation. A miss proves nothing -- the group may still grant access
    through its own rewrite -- so evaluation falls back to recursion. The query
    can therefore only find an answer earlier, never change one. -}
    provenByDirectGroupMembership rows
      | null targets = pure False
      | otherwise = or <$> traverse confirmBucket (Map.toList buckets)
      where
        targets =
          [ (groupObject, groupRelation)
          | row@TupleRow {tuple} <- rows,
            acceleratable row,
            SubjectSet groupObject groupRelation <- [tuple.subject]
          ]
        buckets =
          Map.fromListWith
            (<>)
            [((groupObject.objectType, groupRelation), [groupObject]) | (groupObject, groupRelation) <- targets]

    confirmBucket ((groupType, groupRelation), groupObjects) = do
      rows <- drainStartingWithUser state.budget.pageLimit revision groupType groupRelation candidates
      pure (any grantsDirectly rows)
      where
        grantsDirectly TupleRow {tuple} =
          tuple.object `elem` groupObjects
            && isNothing tuple.caveat

    -- Residuals accumulate reversed and are flipped back by the caller: appending
    -- one row at a time to the tail copies the list per row, and a relation
    -- attached to n groups then costs n^2 conses to fold.
    rowResidual (residuals, memo', taint) TupleRow {tuple} =
      case tuple.subject of
        SubjectSet subjectObject subjectRelation -> do
          (residual, memo'', rowTaint) <- evalRelationMemo cacheOps graph revision subject subjectObject subjectRelation state memo'
          pure ((residual >>= residualGate graph tuple.caveat) : residuals, memo'', taint <> rowTaint)
        _ ->
          pure (residuals, memo', taint)

-- | Does @objectType#relation@ union in its directly-stored tuples?
--
-- Only then does a stored membership tuple by itself prove the relation holds. A
-- relation whose rewrite is an intersection, an exclusion, or an arrow may ignore
-- its own stored tuples, or subtract from them.
relationUnionsThis :: ReachabilityGraph -> ObjectType -> RelationName -> Bool
relationUnionsThis graph objectType relation =
  case Map.lookup RelationRef {objectType, relation} graph.relations of
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
  Revision ->
  Subject ->
  ObjectRef ->
  RelationName ->
  RelationName ->
  EvalState ->
  CheckMemo ->
  Eff es (Either EnError ResidualDecision, CheckMemo, CutTaint)
evalTupleToUsersetMemo cacheOps graph revision subject object tuplesetRelation computedRelation state memo = do
  rows <- drainObjectRelation state.budget.pageLimit revision object tuplesetRelation
  (residuals, memo', taint) <- foldM rowResidual ([], memo, mempty) rows
  pure (Decision.rUnion <$> sequence (reverse residuals), memo', taint)
  where
    -- Reversed accumulation, as in 'evalThisMemo'. Row order is restored before
    -- 'sequence' runs, because 'sequence' reports the first 'Left' it meets and
    -- which row that is should not depend on how the list was built.
    rowResidual (residuals, memo', taint) TupleRow {tuple} =
      case tuple.subject of
        SubjectId subjectObject -> do
          (residual, memo'', rowTaint) <- evalRelationMemo cacheOps graph revision subject subjectObject computedRelation state memo'
          pure (applyRowGate tuple residual : residuals, memo'', taint <> rowTaint)
        SubjectSet subjectObject subjectRelation -> do
          (residual, memo'', rowTaint) <- evalRelationMemo cacheOps graph revision subject subjectObject subjectRelation state memo'
          pure (applyRowGate tuple residual : residuals, memo'', taint <> rowTaint)
        SubjectWildcard _ ->
          pure (Right RDenied : residuals, memo', taint)

    applyRowGate tuple =
      (>>= residualGate graph tuple.caveat)

-- | Gate a residual behind a tuple's caveat, if it has one.
--
-- The caveat's /name/ is validated against the schema here, at evaluation time,
-- rather than deferred to 'applyResidual'. Two reasons. An unknown caveat is a
-- schema-or-data defect and should surface where the tuple is read, matching what
-- the inline evaluator did. And it keeps the invariant that a residual reaching the
-- decision cache names only caveats the schema defines, so a cache hit can always
-- be re-applied.
residualGate :: ReachabilityGraph -> Maybe TupleCaveat -> ResidualDecision -> Either EnError ResidualDecision
residualGate _ Nothing residual =
  Right residual
residualGate graph (Just TupleCaveat {name, payload}) residual = do
  requireCaveat graph name
  pure (Decision.rIntersection [RCaveat name payload, residual])

requireCaveat :: ReachabilityGraph -> CaveatName -> Either EnError ()
requireCaveat graph caveat
  | Map.member caveat graph.caveats = Right ()
  | otherwise = Left (UnknownRelation ("unknown caveat: " <> caveatText caveat))

-- | The subjects a stored row may name to grant @subject@ directly: the subject
-- itself, and -- for a concrete subject -- the wildcard over its object type,
-- which means "every object of this type". Mirrors 'En.Lookup.subjectsWithWildcard'.
subjectsWithWildcard :: Subject -> [Subject]
subjectsWithWildcard subject =
  subject
    : case subject of
      SubjectId object -> [SubjectWildcard object.objectType]
      SubjectSet _ _ -> []
      SubjectWildcard _ -> []

-- | Read every row of @object#relation@, following page cursors to the end.
--
-- @pageLimit@ is a batch size here, not a ceiling: a relation with more rows than
-- one page is a large group, and asking whether someone belongs to it is a
-- question with an answer. Mirrors the drain loops in "En.Lookup" and "En.Expand".
drainObjectRelation ::
  (TupleStore :> es) =>
  Int ->
  Revision ->
  ObjectRef ->
  RelationName ->
  Eff es [TupleRow]
drainObjectRelation pageLimit revision object relation =
  drain Nothing []
  where
    -- Pages accumulate reversed and are flattened once. Appending each page to the
    -- tail copies everything read so far, so draining k pages copies O(k^2) rows --
    -- exactly the wide relations the probe exists to make cheap.
    drain cursor acc = do
      page <- readObjectRelation revision object relation pageLimit cursor
      let acc' = page.rows : acc
      case page.state of
        Exhausted -> pure (concat (reverse acc'))
        HasMore next -> drain (Just next) acc'
        Truncated next -> drain (Just next) acc'

-- | Read every @objectType#relation@ row whose subject is one of @subjects@,
-- following page cursors to the end. This is Zanzibar's reverse query: rather than
-- asking each candidate group "do you contain the subject?", ask storage once for
-- all the groups of a type that do. Mirrors 'En.Lookup.readRowsForSubjects'.
drainStartingWithUser ::
  (TupleStore :> es) =>
  Int ->
  Revision ->
  ObjectType ->
  RelationName ->
  [Subject] ->
  Eff es [TupleRow]
drainStartingWithUser _ _ _ _ [] =
  pure []
drainStartingWithUser pageLimit revision objectType relation subjects =
  drain Nothing []
  where
    drain cursor acc = do
      page <-
        readStartingWithUser
          revision
          UsersetQuery
            { queryType = objectType,
              queryRelation = relation,
              querySubjects = subjects,
              queryLimit = pageLimit,
              queryCursor = cursor
            }
      let acc' = page.rows : acc
      case page.state of
        Exhausted -> pure (concat (reverse acc'))
        HasMore next -> drain (Just next) acc'
        Truncated next -> drain (Just next) acc'

renderRef :: RelationRef -> Text
renderRef RelationRef {objectType = ObjectType objectType, relation = RelationName relation} =
  objectType <> "#" <> relation

caveatText :: CaveatName -> Text
caveatText (CaveatName text) =
  text
