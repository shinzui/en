{-# LANGUAGE NoFieldSelectors #-}

{- | Forward expansion, flattened: list the subjects that hold a permission on an
object.

This is the question a sharing dialog asks — "who can view this?" — and it is the one
question the other three engine entrypoints cannot answer. 'En.Check.check' answers it
for one subject at a time. 'En.Lookup.lookup' answers its mirror image (which objects
does this subject reach?). 'En.Expand.expand' returns an explanatory /tree/ whose set
operators a client would have to re-implement to flatten, and whose caveats it would
have to re-evaluate; flattening it naively unions an intersection's branches and reports
an exclusion's /subtracted/ subjects as if they were granted.

The result here is flat, cursored, and each subject carries the same 'CheckDecision'
'En.Check.check' would give it, because intersection and exclusion candidates are
confirmed by calling that evaluator rather than by re-deriving its algebra.
-}
module En.LookupSubjects (
    LookupSubjectsRequest (..),
    LookupSubject (..),
    LookupSubjectsState (..),
    LookupSubjectsPage (..),
    LookupSubjectsCursor (..),
    LookupSubjectsCursorState (..),
    encodeLookupSubjectsCursor,
    decodeLookupSubjectsCursor,
    resolveLookupSubjectsCursor,
    lookupSubjects,
    lookupSubjectsCached,
    lookupSubjectsWithDeadline,
    lookupSubjectsWithDeadlineCached,
    lookupSubjectsWithDeadlineAndBudget,
    lookupSubjectsWithDeadlineCachedAndBudget,
) where

import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Set (Set)
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text qualified as Text
import Effectful (Eff, IOE, raise, (:>))
import Effectful.Error.Static (Error, runErrorNoCallStack, throwError)
import Text.Read (readMaybe)

import En.Budget (EvaluationBudget (..), defaultEvaluationBudget)
import En.Caveat (evaluateCaveat)
import En.Check (CheckCacheEnv, CheckDecision (..), CheckMemo, checkAtRevisionWithBudget, checkCachedAtRevisionWithBudget, emptyCheckMemo)
import En.Decision qualified as Decision
import En.Effect.ConsistencyStore (ConsistencyStore, ResolvedConsistency (..), TokenMetadata (..), decodeToken, mintToken, resolveConsistency, validateToken)
import En.Effect.TupleStore (PageState (..), TuplePage (..), TupleRow (..), TupleStore, readObjectRelation)
import En.Error (EnError (..))
import En.Lookup (Deadline (..), noDeadline)
import En.Reachability (ReachabilityGraph (..), RelationRef (..))
import En.Revision (Consistency, ConsistencyToken (..), Revision)
import En.Schema (CaveatName (..), ObjectType (..), Relation (..), RelationName (..), Rewrite (..))
import En.Tuple (
    CaveatContext,
    CaveatPayload (..),
    ObjectRef (..),
    Subject (..),
    Tuple (..),
    TupleCaveat (..),
 )

newtype LookupSubjectsCursor = LookupSubjectsCursor
    { cursorEncoding :: Text
    }
    deriving stock (Eq, Ord, Show)

{- | The state a lookup-subjects cursor carries between pages.

The snapshot is pinned by a 'ConsistencyToken' rather than by a raw revision, for the
reason 'En.Lookup.LookupCursorState' gives: a cursor is client-supplied text, and a raw
revision inside it would let a forged cursor read at any snapshot the caller named,
including one past the garbage-collection horizon. A token is the one thing the
datastore can verify.

'lastSubject' is the watermark: the greatest subject emitted so far. Results are merged
into a map keyed by subject and read out in ascending key order, so "everything strictly
after the watermark" is exactly "everything not yet emitted". That is what keeps pages
free of duplicates and gaps even though each page recomputes the traversal.
-}
data LookupSubjectsCursorState = LookupSubjectsCursorState
    { version :: !Int
    , token :: !ConsistencyToken
    , lastSubject :: !(Maybe Subject)
    }
    deriving stock (Eq, Show)

{- | Who to ask about, and how much of the answer to return.

@subjectType@ is mandatory and names one object type (typically @user@). It keeps the
traversal bounded and the result homogeneous. "Every subject of every type" is an audit
question, better served by 'En.Expand.expand' together with the relationship read filter.
-}
data LookupSubjectsRequest = LookupSubjectsRequest
    { object :: !ObjectRef
    , permission :: !RelationName
    , subjectType :: !ObjectType
    , context :: !CaveatContext
    , limit :: !Int
    , cursor :: !(Maybe LookupSubjectsCursor)
    }
    deriving stock (Eq, Show)

{- | One subject holding the permission, and on what terms.

@subject@ is a concrete 'SubjectId' of the requested type, or a 'SubjectWildcard' over
it. A wildcard is never expanded into concrete subjects — the set of users is not en's
data — so it surfaces as its own entry and a client renders it as "everyone".
-}
data LookupSubject = LookupSubject
    { subject :: !Subject
    , decision :: !CheckDecision
    }
    deriving stock (Eq, Show)

data LookupSubjectsState
    = SubjectsExhausted
    | SubjectsHasMore !LookupSubjectsCursor
    | SubjectsTruncated !LookupSubjectsCursor
    deriving stock (Eq, Ord, Show)

{- | One page of subjects, and the snapshot the whole lookup reads at.

'checkedAt' is the same token the outgoing cursor pins, so every page of one traversal
reports the same value: consistency is resolved once, and a continuation reads at the
revision its cursor's /validated/ token names. A caller can chain a follow-up read at
@AtLeastAsFresh@ this token and be certain of observing everything the page observed.
-}
data LookupSubjectsPage = LookupSubjectsPage
    { subjects :: ![LookupSubject]
    , state :: !LookupSubjectsState
    , checkedAt :: !ConsistencyToken
    }
    deriving stock (Eq, Show)

{- | List the subjects of @subjectType@ holding @permission@ on @object@.

Cursor-resumable at a pinned snapshot, not streamed. A lookup-subjects resolves
consistency /once/ and every page of it — including the forward checks that confirm
intersection and exclusion candidates — reads the same snapshot. The cursor carries a
'ConsistencyToken' pinning it, validated on resume exactly as any token presented on a
read: datastore identity, schema hash, garbage-collection window. A tampered, foreign, or
expired cursor is refused with @InvalidConsistencyToken "lookup-subjects cursor"@, and is
recovered from by restarting without one.

Results are ordered by subject and the cursor records the last one emitted, which is what
keeps pages free of duplicates and gaps. Continuation pages recompute the traversal and
filter its output against that watermark; see the module header of "En.Lookup" for why
resuming a rewrite walk in place is harder than it sounds.

The deadline interrupts the walk rather than labelling its result. A lookup-subjects that
runs out of budget returns 'SubjectsTruncated' with /no subjects/ and an unmoved
watermark, because the subjects found before the interruption are an arbitrary subset of
the answer rather than its smallest members — emitting them would advance the watermark
past results not yet discovered. Retry with a budget sufficient for one page.
-}
lookupSubjects ::
    (ConsistencyStore :> es, TupleStore :> es, Error EnError :> es) =>
    ReachabilityGraph ->
    Consistency ->
    LookupSubjectsRequest ->
    Eff es LookupSubjectsPage
lookupSubjects =
    lookupSubjectsWithDeadline noDeadline

lookupSubjectsWithDeadline ::
    (ConsistencyStore :> es, TupleStore :> es, Error EnError :> es) =>
    Deadline (Eff es) ->
    ReachabilityGraph ->
    Consistency ->
    LookupSubjectsRequest ->
    Eff es LookupSubjectsPage
lookupSubjectsWithDeadline =
    lookupSubjectsWithDeadlineAndBudget defaultEvaluationBudget

{- | 'lookupSubjectsWithDeadline' under caller-chosen evaluation bounds.

The budget and the deadline are both bounds and they are not the same bound: the budget
is static (how deep to recurse, how many rows to read at a time, how many subjects a page
may hold), the deadline is a live clock the traversal polls. See "En.Budget". The
confirmations run under the same budget as the walk.
-}
lookupSubjectsWithDeadlineAndBudget ::
    (ConsistencyStore :> es, TupleStore :> es, Error EnError :> es) =>
    EvaluationBudget ->
    Deadline (Eff es) ->
    ReachabilityGraph ->
    Consistency ->
    LookupSubjectsRequest ->
    Eff es LookupSubjectsPage
lookupSubjectsWithDeadlineAndBudget budget =
    lookupSubjectsWithChecker budget (ConfirmCheck (checkAtRevisionWithBudget budget))

lookupSubjectsCached ::
    (ConsistencyStore :> es, TupleStore :> es, IOE :> es, Error EnError :> es) =>
    CheckCacheEnv ->
    ReachabilityGraph ->
    Consistency ->
    LookupSubjectsRequest ->
    Eff es LookupSubjectsPage
lookupSubjectsCached cacheEnv =
    lookupSubjectsWithDeadlineCached cacheEnv noDeadline

lookupSubjectsWithDeadlineCached ::
    (ConsistencyStore :> es, TupleStore :> es, IOE :> es, Error EnError :> es) =>
    CheckCacheEnv ->
    Deadline (Eff es) ->
    ReachabilityGraph ->
    Consistency ->
    LookupSubjectsRequest ->
    Eff es LookupSubjectsPage
lookupSubjectsWithDeadlineCached =
    lookupSubjectsWithDeadlineCachedAndBudget defaultEvaluationBudget

-- | 'lookupSubjectsWithDeadlineCached' under caller-chosen evaluation bounds. See "En.Budget".
lookupSubjectsWithDeadlineCachedAndBudget ::
    (ConsistencyStore :> es, TupleStore :> es, IOE :> es, Error EnError :> es) =>
    EvaluationBudget ->
    CheckCacheEnv ->
    Deadline (Eff es) ->
    ReachabilityGraph ->
    Consistency ->
    LookupSubjectsRequest ->
    Eff es LookupSubjectsPage
lookupSubjectsWithDeadlineCachedAndBudget budget cacheEnv =
    lookupSubjectsWithChecker budget (ConfirmCheck (checkCachedAtRevisionWithBudget budget cacheEnv))

{- | How one over-generated candidate is confirmed.

Pinned to a revision — the one this call resolved once, up front — and threading a memo
so a batch of confirmations shares subproblems rather than re-reading the same groups per
candidate. The same indirection "En.Lookup" uses, so a host can supply the decision-cached
evaluator without this module knowing about caches.
-}
newtype ConfirmCheck es = ConfirmCheck
    { runConfirm ::
        ReachabilityGraph ->
        CaveatContext ->
        Revision ->
        Subject ->
        RelationName ->
        ObjectRef ->
        CheckMemo ->
        Eff es (Either EnError CheckDecision, CheckMemo)
    }

{- | Resolve the snapshot this request reads at, then walk it.

Without a cursor the snapshot comes from the caller's 'Consistency', and the outgoing
cursor pins it with a freshly minted token so the next page continues on the same
snapshot. With a cursor the snapshot comes from that cursor's /validated/ token, and the
request's 'Consistency' is not consulted at all: re-resolving it on a continuation would
silently span two snapshots and produce a page with gaps.
-}
lookupSubjectsWithChecker ::
    (ConsistencyStore :> es, TupleStore :> es, Error EnError :> es) =>
    EvaluationBudget ->
    ConfirmCheck es ->
    Deadline (Eff es) ->
    ReachabilityGraph ->
    Consistency ->
    LookupSubjectsRequest ->
    Eff es LookupSubjectsPage
lookupSubjectsWithChecker budget confirm deadline graph consistency request =
    case request.cursor of
        Just cursor -> do
            resolved <- resolveLookupSubjectsCursor cursor
            (revision, cursorState) <- either throwError pure resolved
            run revision cursorState.token (Just cursorState)
        Nothing -> do
            ResolvedConsistency{revision} <- resolveConsistency consistency
            token <- mintToken revision
            run revision token Nothing
  where
    run revision token cursorState =
        either throwError pure
            =<< runLookupSubjects budget confirm deadline graph revision token cursorState request

runLookupSubjects ::
    (TupleStore :> es) =>
    EvaluationBudget ->
    ConfirmCheck es ->
    Deadline (Eff es) ->
    ReachabilityGraph ->
    Revision ->
    ConsistencyToken ->
    Maybe LookupSubjectsCursorState ->
    LookupSubjectsRequest ->
    Eff es (Either EnError LookupSubjectsPage)
runLookupSubjects budget confirm deadline graph revision token cursorState request = do
    outcome <-
        runErrorNoCallStack
            (evalRelation traversal request.object request.permission (initialState budget))
    case outcome of
        Left Interrupt ->
            pure (Right (interruptedPage cursorState token))
        Right subjects ->
            -- The one place the working set becomes a list. 'Map.toAscList' is already
            -- ascending by subject, which is the order pages and watermarks assume.
            traverse (pageSubjects budget deadline request.limit cursorState token) subjects
  where
    traversal =
        Traversal
            { confirm = raiseConfirm confirm
            , deadline = raiseDeadline deadline
            , graph
            , context = request.context
            , revision
            , subjectType = request.subjectType
            }

{- | The traversal ran out of budget before it could decide anything.

The page carries /no new subjects/ and the watermark does not move. That is the only
sound answer: the subjects discovered before the interruption are an arbitrary subset of
the result, not its smallest members. Emitting @zoe@ while an unexplored branch still
holds @alice@ would advance the watermark past @alice@, and the next page — filtering to
subjects strictly greater than @zoe@ — would never return her. A gap, silently.
-}
interruptedPage :: Maybe LookupSubjectsCursorState -> ConsistencyToken -> LookupSubjectsPage
interruptedPage cursorState token =
    LookupSubjectsPage
        { subjects = []
        , state =
            SubjectsTruncated
                ( encodeLookupSubjectsCursor
                    LookupSubjectsCursorState
                        { version = 1
                        , token
                        , lastSubject = cursorState >>= (.lastSubject)
                        }
                )
        , checkedAt = token
        }

{- | The traversal's budget ran out. Raised inside the walk and caught by
'runLookupSubjects', which never lets it escape to the caller: it is a paging outcome,
not an error.
-}
data Interrupt = Interrupt
    deriving stock (Eq, Show)

-- | Stop the traversal unless the caller's budget still permits more store work.
requireBudget :: (Error Interrupt :> es) => Deadline (Eff es) -> Eff es ()
requireBudget deadline = do
    hasBudget <- deadline.remainingBudget
    if hasBudget then pure () else throwError Interrupt

raiseDeadline :: Deadline (Eff es) -> Deadline (Eff (Error Interrupt : es))
raiseDeadline deadline =
    Deadline (raise deadline.remainingBudget)

raiseConfirm :: ConfirmCheck es -> ConfirmCheck (Error Interrupt : es)
raiseConfirm confirm =
    ConfirmCheck \graph context revision subject relation object memo ->
        raise (confirm.runConfirm graph context revision subject relation object memo)

{- | Everything the walk needs that does not change as it descends.

Threading these as arguments, as "En.Lookup" does, made nine-parameter evaluators whose
call sites could transpose two 'RelationName's without a type error.
-}
data Traversal es = Traversal
    { confirm :: !(ConfirmCheck es)
    , deadline :: !(Deadline (Eff es))
    , graph :: !ReachabilityGraph
    , context :: !CaveatContext
    , revision :: !Revision
    , subjectType :: !ObjectType
    }

data EvalState = EvalState
    { depth :: !Int
    , visited :: !(Set Subproblem)
    , budget :: !EvaluationBudget
    }

data Subproblem = Subproblem
    { object :: !ObjectRef
    , relation :: !RelationName
    }
    deriving stock (Eq, Ord, Show)

initialState :: EvaluationBudget -> EvalState
initialState budget =
    EvalState{depth = 0, visited = Set.empty, budget}

{- | The traversal's working set: subjects mapped to the terms on which they hold.

A map rather than a sorted list because every combining node merges, and 'Map.toAscList'
already yields the order pages and watermarks assume, so the list is materialized once at
the boundary that needs it.
-}
type LookupSubjectsMap = Map Subject CheckDecision

{- | Expand @object#relation@ into the subjects it grants.

A revisited subproblem contributes the empty set rather than an error. Zanzibar's
semantics for a membership recursion is its least fixpoint, and a cycle adds nothing to
it; this is what 'En.Lookup.evalRelation' already does, and a brand-new API must not
inherit 'En.Expand.expand'\'s harsher revisit-is-a-cycle-error behavior, which exists
because a tree hiding a branch would mislead an auditor.
-}
evalRelation ::
    (TupleStore :> es, Error Interrupt :> es) =>
    Traversal es ->
    ObjectRef ->
    RelationName ->
    EvalState ->
    Eff es (Either EnError LookupSubjectsMap)
evalRelation env object relation state
    | state.depth >= state.budget.maxDepth =
        pure (Left ResolutionLimitExceeded)
    | Set.member subproblem state.visited =
        pure (Right Map.empty)
    | otherwise =
        case Map.lookup ref env.graph.relations of
            Nothing ->
                pure (Left (UnknownRelation (renderRef ref)))
            Just schemaRelation ->
                evalRewrite
                    env
                    object
                    relation
                    schemaRelation.rewrite
                    state{depth = state.depth + 1, visited = Set.insert subproblem state.visited}
  where
    ref = RelationRef{objectType = object.objectType, relation}
    subproblem = Subproblem{object, relation}

{- | Expand one rewrite node.

'Intersection' and 'Exclusion' are the two nodes a forward walk cannot answer by
collecting: their branches over-generate. Both therefore gather candidates and confirm
each one with a full forward 'En.Check.check' of that subject against @currentRelation@ on
@object@ — reach-then-check, exactly as 'En.Lookup' confirms its own candidates. Doing the
decision algebra inline here would duplicate "En.Decision" and rot independently of it;
delegating means this API cannot silently disagree with @check@.

An 'Exclusion' gathers from its base only. Its subtrahend is never walked: a subject the
subtrahend grants is denied by the confirming check, and a subject /only/ the subtrahend
grants was never a candidate.
-}
evalRewrite ::
    (TupleStore :> es, Error Interrupt :> es) =>
    Traversal es ->
    ObjectRef ->
    RelationName ->
    Rewrite ->
    EvalState ->
    Eff es (Either EnError LookupSubjectsMap)
evalRewrite env object currentRelation rewrite state =
    case rewrite of
        This ->
            evalThis env object currentRelation state
        ComputedUserset relation ->
            evalRelation env object relation state
        TupleToUserset tuplesetRelation computedRelation ->
            evalTupleToUserset env object tuplesetRelation computedRelation state
        Union rewrites ->
            branches rewrites
        Intersection rewrites ->
            confirmCandidates env object currentRelation =<< branches rewrites
        Exclusion base _subtractRewrite ->
            confirmCandidates env object currentRelation
                =<< evalRewrite env object currentRelation base state
        Caveated caveat inner -> do
            expanded <- evalRewrite env object currentRelation inner state
            pure (applyRewriteCaveat env.graph env.context caveat =<< expanded)
  where
    -- One budget poll per branch. A branch is the coarsest unit of traversal work that
    -- can be skipped whole, and polling any finer costs a clock read per row.
    branches rewrites = do
        results <-
            traverse
                ( \current -> do
                    requireBudget env.deadline
                    evalRewrite env object currentRelation current state
                )
                rewrites
        pure (mergeAllSubjects <$> sequence results)

{- | The directly-stored tuples of @object#relation@.

A concrete or wildcard subject of the requested type is a result in itself. A userset
subject is a group, so it is expanded and everything it yields inherits the granting
row's caveat. Subjects of any other type are skipped: a concrete subject grants only
itself, and this request asked about one type.
-}
evalThis ::
    (TupleStore :> es, Error Interrupt :> es) =>
    Traversal es ->
    ObjectRef ->
    RelationName ->
    EvalState ->
    Eff es (Either EnError LookupSubjectsMap)
evalThis env object relation state = do
    rows <- drainObjectRows env.deadline state.budget.pageLimit env.revision object relation
    case rows of
        Left err -> pure (Left err)
        Right tupleRows -> do
            collected <- traverse subjectsFromRow tupleRows
            pure (mergeAllSubjects <$> sequence collected)
  where
    subjectsFromRow TupleRow{tuple} =
        case tuple.subject of
            SubjectId subjectObject
                | subjectObject.objectType == env.subjectType ->
                    pure (gateLeaf tuple.caveat (SubjectId subjectObject))
                | otherwise -> pure (Right Map.empty)
            SubjectWildcard wildcardType
                | wildcardType == env.subjectType ->
                    pure (gateLeaf tuple.caveat (SubjectWildcard wildcardType))
                | otherwise -> pure (Right Map.empty)
            SubjectSet groupObject groupRelation -> do
                inner <- evalRelation env groupObject groupRelation state
                pure (gateSubjects env tuple.caveat =<< inner)

    gateLeaf caveat subject = do
        gate <- evaluateTupleCaveat env.graph env.context caveat
        pure case Decision.applyGate gate Allowed of
            Denied -> Map.empty
            allowed -> Map.singleton subject allowed

{- | The arrow: follow @tuplesetRelation@ to a target object, then expand a relation
there.

Which relation is expanded on the target follows the tupleset row's own subject, exactly
as 'En.Check.check' does: a concrete subject leads to @computedRelation@ on it, and a
userset subject leads to the relation that userset names. A wildcard tupleset row
contributes nothing — there is no object to follow.
-}
evalTupleToUserset ::
    (TupleStore :> es, Error Interrupt :> es) =>
    Traversal es ->
    ObjectRef ->
    RelationName ->
    RelationName ->
    EvalState ->
    Eff es (Either EnError LookupSubjectsMap)
evalTupleToUserset env object tuplesetRelation computedRelation state = do
    rows <- drainObjectRows env.deadline state.budget.pageLimit env.revision object tuplesetRelation
    case rows of
        Left err -> pure (Left err)
        Right tupleRows -> do
            collected <- traverse expandRow tupleRows
            pure (mergeAllSubjects <$> sequence collected)
  where
    expandRow TupleRow{tuple} =
        case tuple.subject of
            SubjectId target -> follow tuple.caveat target computedRelation
            SubjectSet target targetRelation -> follow tuple.caveat target targetRelation
            SubjectWildcard _ -> pure (Right Map.empty)

    follow caveat target relation = do
        inner <- evalRelation env target relation state
        pure (gateSubjects env caveat =<< inner)

{- | Confirm over-generated candidates with a forward check at the pinned revision.

The memo is folded across the candidate list, so subproblems shared between candidates
are evaluated once: confirming twenty subjects who all inherit from the same group reads
that group once, not twenty times. It holds context-free residual decisions, so sharing
entries between candidates cannot leak one candidate's caveat answers into another's —
the request context is applied per candidate, inside the check.

A wildcard candidate is confirmed as the wildcard subject itself. That fails closed: a
wildcard survives an intersection only if every branch grants the wildcard, and is
subtracted only if the subtrahend grants the wildcard. It can under-report a wildcard's
interaction with concrete-subject branches, and it never fabricates access. A concrete
subject covered by a wildcard in one branch and granted directly in another is still
reported concretely, through its own candidacy.
-}
confirmCandidates ::
    Traversal es ->
    ObjectRef ->
    RelationName ->
    Either EnError LookupSubjectsMap ->
    Eff es (Either EnError LookupSubjectsMap)
confirmCandidates _ _ _ (Left err) =
    pure (Left err)
confirmCandidates env object relation (Right candidates) =
    go emptyCheckMemo Map.empty (Map.keys candidates)
  where
    go _ confirmed [] =
        pure (Right confirmed)
    go memo confirmed (candidate : rest) = do
        (decision, memo') <-
            env.confirm.runConfirm env.graph env.context env.revision candidate relation object memo
        case decision of
            Left err -> pure (Left err)
            Right Denied -> go memo' confirmed rest
            Right allowed -> go memo' (Map.insert candidate allowed confirmed) rest

{- | Drain every page of a forward read, polling the caller's budget /between/ store
pages.

Between, not before: a relation that fits in one page never polls, so a request small
enough to answer always answers. Not per row either — the poll is an effectful action,
and a clock read per row would cost more than the read it guards. Mirrors the drain loops
in "En.Check", "En.Lookup", and "En.Expand".
-}
drainObjectRows ::
    (TupleStore :> es, Error Interrupt :> es) =>
    Deadline (Eff es) ->
    Int ->
    Revision ->
    ObjectRef ->
    RelationName ->
    Eff es (Either EnError [TupleRow])
drainObjectRows deadline pageLimit revision object relation =
    drain Nothing []
  where
    -- Reversed page accumulation, flattened once: appending each page to the tail copies
    -- everything read so far, so draining k pages would copy O(k^2) rows.
    drain cursor acc = do
        page <- readObjectRelation revision object relation pageLimit cursor
        let acc' = page.rows : acc
        case page.state of
            Exhausted -> pure (Right (concat (reverse acc')))
            HasMore next -> continue next acc'
            Truncated next -> continue next acc'

    continue next acc = do
        requireBudget deadline
        drain (Just next) acc

-- | Combine two working sets, joining the terms a subject holds on with 'Decision.union'.
mergeSubjects :: LookupSubjectsMap -> LookupSubjectsMap -> LookupSubjectsMap
mergeSubjects =
    -- Left-biased in obligation order: @left@ is the earlier branch, so a 'Conditional'
    -- decision's obligations keep the order a left-to-right traversal produced.
    Map.unionWith (\left right -> Decision.union [left, right])

mergeAllSubjects :: [LookupSubjectsMap] -> LookupSubjectsMap
mergeAllSubjects =
    foldl' mergeSubjects Map.empty

-- | Gate every subject behind a granting row's caveat, dropping those the gate denies.
gateSubjects :: Traversal es -> Maybe TupleCaveat -> LookupSubjectsMap -> Either EnError LookupSubjectsMap
gateSubjects env caveat subjects = do
    gate <- evaluateTupleCaveat env.graph env.context caveat
    pure (applyGate gate subjects)

{- | Gate every subject behind a rewrite-level @Caveated@ node.

Such a node carries no stored arguments: everything it needs comes from the request
context, so it is evaluated against the empty payload.
-}
applyRewriteCaveat :: ReachabilityGraph -> CaveatContext -> CaveatName -> LookupSubjectsMap -> Either EnError LookupSubjectsMap
applyRewriteCaveat graph context caveat subjects = do
    gate <- evaluateNamedCaveat graph context caveat (CaveatPayload Map.empty)
    pure (applyGate gate subjects)

applyGate :: CheckDecision -> LookupSubjectsMap -> LookupSubjectsMap
applyGate gate =
    Map.mapMaybe
        ( \decision ->
            case Decision.applyGate gate decision of
                Denied -> Nothing
                gated -> Just gated
        )

evaluateTupleCaveat :: ReachabilityGraph -> CaveatContext -> Maybe TupleCaveat -> Either EnError CheckDecision
evaluateTupleCaveat _ _ Nothing =
    Right Allowed
evaluateTupleCaveat graph context (Just TupleCaveat{name, payload}) =
    evaluateNamedCaveat graph context name payload

evaluateNamedCaveat :: ReachabilityGraph -> CaveatContext -> CaveatName -> CaveatPayload -> Either EnError CheckDecision
evaluateNamedCaveat graph context caveat payload =
    case Map.lookup caveat graph.caveats of
        Nothing -> Left (UnknownRelation ("unknown caveat: " <> caveatText caveat))
        Just definition -> Right (evaluateCaveat definition payload context)

{- | Slice the merged subject set into one page.

Every page recomputes the whole traversal and then filters against the watermark. That is
the same mechanic 'En.Lookup.pageLookup' uses, and it carries the same known cost: page
@n@ redoes the work of pages @1..n-1@. Keeping the two endpoints identical means whatever
fixes lookup's paging fixes this too; a private streaming design in one endpoint would
not transfer.
-}
pageSubjects ::
    (Monad m) =>
    EvaluationBudget ->
    Deadline m ->
    Int ->
    Maybe LookupSubjectsCursorState ->
    ConsistencyToken ->
    LookupSubjectsMap ->
    m LookupSubjectsPage
pageSubjects budget deadline rawLimit cursorState token subjects = do
    hasBudget <- deadline.remainingBudget
    let limit = max 0 rawLimit
        startAfter = cursorState >>= (.lastSubject)
        ordered = [LookupSubject{subject, decision} | (subject, decision) <- Map.toAscList subjects]
        remaining =
            case startAfter of
                Nothing -> ordered
                Just lastSeen -> filter (\found -> found.subject > lastSeen) ordered
        visible = take (min budget.resultCap limit) remaining
        hasMore = length visible < length remaining
        nextCursor =
            LookupSubjectsCursorState
                { version = 1
                , token
                , lastSubject = (.subject) <$> lastMaybe visible
                }
        state
            | hasMore && hasBudget = SubjectsHasMore (encodeLookupSubjectsCursor nextCursor)
            | hasMore = SubjectsTruncated (encodeLookupSubjectsCursor nextCursor)
            | otherwise = SubjectsExhausted
    pure LookupSubjectsPage{subjects = visible, state, checkedAt = token}

lastMaybe :: [a] -> Maybe a
lastMaybe =
    \case
        [] -> Nothing
        values -> Just (last values)

{- | Encode cursor state as opaque text.

The same length-prefixed field codec "En.Lookup" uses, so no escaping is needed:

@
lookupsubjects-v1 |token |subjectKind |objectType |objectId |relation
@

@subjectKind@ is empty when no subject has been emitted yet. It is @id@, @wildcard@, or
@set@ otherwise; @set@ cannot arise from a result (a page holds only concrete and
wildcard subjects of the requested type) but the codec is total so the watermark type can
stay a plain 'Subject'.
-}
encodeLookupSubjectsCursor :: LookupSubjectsCursorState -> LookupSubjectsCursor
encodeLookupSubjectsCursor LookupSubjectsCursorState{token, lastSubject} =
    LookupSubjectsCursor $
        Text.concat
            ( "lookupsubjects-v1"
                : encodeField tokenText
                : (encodeField <$> encodeSubject lastSubject)
            )
  where
    ConsistencyToken tokenText = token

-- | @(kind, objectType, objectId, relation)@, flattened. Absent fields encode as empty.
encodeSubject :: Maybe Subject -> [Text]
encodeSubject = \case
    Nothing -> ["", "", "", ""]
    Just (SubjectId object) -> ["id", objectText object.objectType, object.objectId, ""]
    Just (SubjectWildcard objectType) -> ["wildcard", objectText objectType, "", ""]
    Just (SubjectSet object relation) ->
        ["set", objectText object.objectType, object.objectId, relationText relation]

{- | Parse cursor text. This is /parsing only/ — it does not validate the embedded token,
and its 'Right' therefore does not mean the cursor may be obeyed. Callers inside the
engine go through 'resolveLookupSubjectsCursor'.
-}
decodeLookupSubjectsCursor :: LookupSubjectsCursor -> Either EnError LookupSubjectsCursorState
decodeLookupSubjectsCursor (LookupSubjectsCursor cursorText) =
    maybe (Left invalidCursor) Right do
        body <- Text.stripPrefix "lookupsubjects-v1" cursorText
        ([tokenText, kind, objectTypeText, objectId, relation], rest) <- parseFieldsPrefix 5 body
        if Text.null rest then Just () else Nothing
        lastSubject <- decodeSubject kind objectTypeText objectId relation
        pure LookupSubjectsCursorState{version = 1, token = ConsistencyToken tokenText, lastSubject}

decodeSubject :: Text -> Text -> Text -> Text -> Maybe (Maybe Subject)
decodeSubject kind objectTypeText objectId relation =
    case kind of
        "" -> Just Nothing
        "id" -> Just (Just (SubjectId ObjectRef{objectType = ObjectType objectTypeText, objectId}))
        "wildcard" -> Just (Just (SubjectWildcard (ObjectType objectTypeText)))
        "set" ->
            Just
                ( Just
                    ( SubjectSet
                        ObjectRef{objectType = ObjectType objectTypeText, objectId}
                        (RelationName relation)
                    )
                )
        _ -> Nothing

{- | Parse, then verify, an incoming cursor, returning the snapshot it pins.

A cursor arrives as client text. Its token is decoded and validated by the datastore
exactly as any consistency token presented on a read would be — same datastore identity,
same schema hash, same garbage-collection horizon — and the revision the continuation
reads at comes from the /validated/ token metadata, never from the cursor's own bytes.

A malformed cursor is 'Left' here. A well-formed cursor carrying a token the datastore
rejects raises through the ambient error effect, exactly as 'resolveConsistency' does for
a bad @AtExactSnapshot@ token.
-}
resolveLookupSubjectsCursor ::
    (ConsistencyStore :> es) =>
    LookupSubjectsCursor ->
    Eff es (Either EnError (Revision, LookupSubjectsCursorState))
resolveLookupSubjectsCursor cursor =
    case decodeLookupSubjectsCursor cursor of
        Left err -> pure (Left err)
        Right cursorState -> do
            metadata <- decodeToken cursorState.token
            validateToken metadata
            pure (Right (metadata.revision, cursorState))

invalidCursor :: EnError
invalidCursor =
    InvalidConsistencyToken "lookup-subjects cursor"

encodeField :: Text -> Text
encodeField value =
    "|" <> showText (Text.length value) <> ":" <> value

-- | Parse @expected@ length-prefixed fields, returning them and whatever follows.
parseFieldsPrefix :: Int -> Text -> Maybe ([Text], Text)
parseFieldsPrefix = go
  where
    go 0 rest = Just ([], rest)
    go remaining rest = do
        afterPipe <- Text.stripPrefix "|" rest
        let (lengthText, afterLength) = Text.breakOn ":" afterPipe
        afterColon <- Text.stripPrefix ":" afterLength
        fieldLength <- readMaybe (Text.unpack lengthText)
        let (field, next) = Text.splitAt fieldLength afterColon
        if Text.length field == fieldLength
            then do
                (fields, finalRest) <- go (remaining - 1) next
                Just (field : fields, finalRest)
            else Nothing

showText :: (Show a) => a -> Text
showText =
    Text.pack . show

renderRef :: RelationRef -> Text
renderRef RelationRef{objectType = ObjectType objectType, relation = RelationName relation} =
    objectType <> "#" <> relation

caveatText :: CaveatName -> Text
caveatText (CaveatName text) =
    text

objectText :: ObjectType -> Text
objectText (ObjectType text) =
    text

relationText :: RelationName -> Text
relationText (RelationName text) =
    text
