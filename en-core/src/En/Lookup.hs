{-# LANGUAGE NoFieldSelectors #-}

-- | Reverse expansion: list the objects a subject can reach with a permission.
module En.Lookup (
    LookupCursor (..),
    LookupCursorState (..),
    FrontierEntry (..),
    LookupLimit (..),
    LookupRequest (..),
    LookupObject (..),
    LookupState (..),
    LookupPage (..),
    Deadline (..),
    noDeadline,
    encodeLookupCursor,
    decodeLookupCursor,
    resolveCursor,
    lookup,
    lookupCached,
    lookupWithDeadline,
    lookupWithDeadlineCached,
    lookupWithDeadlineAndBudget,
    lookupWithDeadlineCachedAndBudget,
) where

import Prelude hiding (lookup)

import Data.List (sortOn)
import Data.Map.Strict qualified as Map
import Data.Maybe (catMaybes)
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
import En.Effect.TupleStore (PageState (..), StoreCursor (..), TuplePage (..), TupleRow (..), TupleStore, UsersetQuery (..), readStartingWithUser)
import En.Error (EnError (..))
import En.Reachability (ReachabilityGraph (..), RelationRef (..))
import En.Revision (Consistency, ConsistencyToken (..), Revision)
import En.Schema (AllowedSubject (..), CaveatName (..), ObjectType (..), Relation (..), RelationName (..), Rewrite (..))
import En.Tuple (
    CaveatContext (..),
    CaveatPayload (..),
    ObjectRef (..),
    Subject (..),
    Tuple (..),
    TupleCaveat (..),
 )

newtype LookupCursor = LookupCursor
    { cursorEncoding :: Text
    }
    deriving stock (Eq, Ord, Show)

{- | The state a lookup cursor carries between pages.

The snapshot is pinned by a 'ConsistencyToken', not by raw revision text. A cursor
is client-supplied input, and the revision inside it decides which snapshot the
continuation reads; taking that revision on trust let a forged cursor read at an
arbitrary revision, including past the garbage-collection horizon where deleted
rows have been physically reaped. A token is the one thing the datastore can
verify -- identity, schema hash, GC window -- so the cursor carries one and
'resolveCursor' checks it.

'lastObject' is the watermark: the greatest object key emitted so far. Results are
merged and sorted by object key, so "everything strictly after the watermark"
is exactly "everything not yet emitted", regardless of how much of the traversal a
continuation recomputes. This is what keeps pages free of duplicates and gaps.

'frontier' records per-branch progress for the direct-read stage so a continuation
can resume the underlying store scans instead of restarting them.
-}
data LookupCursorState = LookupCursorState
    { version :: !Int
    , token :: !ConsistencyToken
    , lastObject :: !(Maybe ObjectRef)
    , frontier :: ![FrontierEntry]
    }
    deriving stock (Eq, Show)

{- | How far one direct-read branch of the traversal has been consumed.

A branch is named by the @readStartingWithUser@ query it issues -- the
@(ObjectType, RelationName)@ pair -- plus an ordinal distinguishing repeats of the
same pair. Branch enumeration is deterministic (the rewrite tree is walked
structurally and allowed subjects come from @Set.toAscList@), so the same ordinal
names the same branch on every page.
-}
data FrontierEntry = FrontierEntry
    { branchType :: !ObjectType
    , branchRelation :: !RelationName
    , branchOrdinal :: !Int
    , branchCursor :: !(Maybe StoreCursor)
    , branchExhausted :: !Bool
    }
    deriving stock (Eq, Show)

newtype LookupLimit = LookupLimit
    { unLookupLimit :: Int
    }
    deriving stock (Eq, Ord, Show)

newtype Deadline m = Deadline
    { remainingBudget :: m Bool
    }

noDeadline :: (Applicative m) => Deadline m
noDeadline =
    Deadline (pure True)

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
entrypoints (intersection / exclusion / caveats). This is the read-filter
primitive (e.g. kawa filtering the activity stream).

Cursor-resumable at a pinned snapshot, not streamed. Precisely:

A lookup resolves consistency /once/ and every page of it, including the forward
checks that confirm intersection and exclusion candidates, reads the same snapshot.
The cursor carries a 'En.Revision.ConsistencyToken' pinning that snapshot, and a
continuation is validated exactly as any token presented on a read -- datastore
identity, schema hash, garbage-collection window. A tampered, foreign, or expired
cursor is refused with @InvalidConsistencyToken "lookup cursor"@. Cursors from the
retired @lookup-v1@ format are refused for the same reason: they carried a raw
revision that a client could choose. A refused cursor is recoverable by restarting
the lookup without one, and cursors expire with the GC window, so a client that
sits on one for a day should expect to.

Results are ordered by object key and a cursor records the last one emitted, which
is what keeps pages free of duplicates and gaps. Continuation pages do /not/ resume
the reverse walk where it stopped: the walk is recomputed and its output filtered
against that watermark. What a continuation does avoid is re-confirming candidates
earlier pages already emitted, and confirmation -- a forward check per candidate --
is the expensive half. Confirmation is bounded to the page: it stops once enough
candidates have been allowed to fill it.

The deadline interrupts the walk rather than labelling its result. It is polled
between store pages, before each branch, and before each round of recursive arrow
expansion. A lookup that runs out of budget returns 'LookupTruncated' with /no
objects/ and an unmoved watermark, because the objects found before the interruption
are an arbitrary subset of the answer rather than its smallest members -- emitting
them would advance the watermark past results not yet discovered. Retry with a
budget sufficient for one page.
-}
lookup ::
    (ConsistencyStore :> es, TupleStore :> es, Error EnError :> es) =>
    ReachabilityGraph ->
    Consistency ->
    LookupRequest ->
    Eff es LookupPage
lookup =
    lookupWithDeadline noDeadline

lookupWithDeadline ::
    (ConsistencyStore :> es, TupleStore :> es, Error EnError :> es) =>
    Deadline (Eff es) ->
    ReachabilityGraph ->
    Consistency ->
    LookupRequest ->
    Eff es LookupPage
lookupWithDeadline =
    lookupWithDeadlineAndBudget defaultEvaluationBudget

{- | 'lookupWithDeadline' under caller-chosen evaluation bounds.

The budget and the deadline are both bounds and they are not the same bound: the
budget is static (how deep to recurse, how many rows to read at a time, how many
objects a page may hold), the deadline is a live clock the traversal polls. See
"En.Budget". The lookup's confirmations run under the same budget as its walk.
-}
lookupWithDeadlineAndBudget ::
    (ConsistencyStore :> es, TupleStore :> es, Error EnError :> es) =>
    EvaluationBudget ->
    Deadline (Eff es) ->
    ReachabilityGraph ->
    Consistency ->
    LookupRequest ->
    Eff es LookupPage
lookupWithDeadlineAndBudget budget deadline graph consistency request = do
    lookupWithDeadlineWithChecker budget (CheckForCandidate (checkAtRevisionWithBudget budget)) deadline graph consistency request

lookupCached ::
    (ConsistencyStore :> es, TupleStore :> es, IOE :> es, Error EnError :> es) =>
    CheckCacheEnv ->
    ReachabilityGraph ->
    Consistency ->
    LookupRequest ->
    Eff es LookupPage
lookupCached cacheEnv =
    lookupWithDeadlineCached cacheEnv noDeadline

lookupWithDeadlineCached ::
    (ConsistencyStore :> es, TupleStore :> es, IOE :> es, Error EnError :> es) =>
    CheckCacheEnv ->
    Deadline (Eff es) ->
    ReachabilityGraph ->
    Consistency ->
    LookupRequest ->
    Eff es LookupPage
lookupWithDeadlineCached =
    lookupWithDeadlineCachedAndBudget defaultEvaluationBudget

-- | 'lookupWithDeadlineCached' under caller-chosen evaluation bounds. See "En.Budget".
lookupWithDeadlineCachedAndBudget ::
    (ConsistencyStore :> es, TupleStore :> es, IOE :> es, Error EnError :> es) =>
    EvaluationBudget ->
    CheckCacheEnv ->
    Deadline (Eff es) ->
    ReachabilityGraph ->
    Consistency ->
    LookupRequest ->
    Eff es LookupPage
lookupWithDeadlineCachedAndBudget budget cacheEnv =
    lookupWithDeadlineWithChecker budget (CheckForCandidate (checkCachedAtRevisionWithBudget budget cacheEnv))

{- | How a lookup confirms one over-generated candidate.

Pinned to a revision -- the one the lookup resolved once, up front -- and threading
a memo so a batch of confirmations shares subproblems rather than re-reading the
same groups per candidate.
-}
newtype CheckForCandidate es = CheckForCandidate
    { runCandidateCheck ::
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

Without a cursor the snapshot comes from the caller's 'Consistency', and the
outgoing cursor pins it with a freshly minted token so the next page continues on
the same snapshot. With a cursor the snapshot comes from that cursor's /validated/
token; the same token is threaded back out so a lookup stays on one snapshot for
its whole life, however many pages it takes.
-}
lookupWithDeadlineWithChecker ::
    (ConsistencyStore :> es, TupleStore :> es, Error EnError :> es) =>
    EvaluationBudget ->
    CheckForCandidate es ->
    Deadline (Eff es) ->
    ReachabilityGraph ->
    Consistency ->
    LookupRequest ->
    Eff es LookupPage
lookupWithDeadlineWithChecker budget candidateCheck deadline graph consistency request =
    case request.cursor of
        Just cursor -> do
            resolved <- resolveCursor cursor
            (revision, cursorState) <- either throwError pure resolved
            run revision cursorState.token (Just cursorState)
        Nothing -> do
            ResolvedConsistency{revision} <- resolveConsistency consistency
            token <- mintToken revision
            run revision token Nothing
  where
    run revision token cursorState =
        either throwError pure =<< runLookup budget candidateCheck deadline graph revision token cursorState request

runLookup ::
    (TupleStore :> es) =>
    EvaluationBudget ->
    CheckForCandidate es ->
    Deadline (Eff es) ->
    ReachabilityGraph ->
    Revision ->
    ConsistencyToken ->
    Maybe LookupCursorState ->
    LookupRequest ->
    Eff es (Either EnError LookupPage)
runLookup budget candidateCheck deadline graph revision token cursorState request = do
    outcome <-
        runErrorNoCallStack
            ( evalRelation
                (Just emitWindow)
                (raiseCheckForCandidate candidateCheck)
                (raiseDeadline deadline)
                graph
                request.context
                revision
                request.subject
                request.objectType
                request.permission
                (initialState budget)
            )
    case outcome of
        Left Interrupt ->
            pure (Right (interruptedPage cursorState token))
        Right candidates ->
            traverse (pageLookup budget deadline request.limit cursorState token) candidates
  where
    emitWindow =
        EmitWindow
            { watermark = cursorState >>= (.lastObject)
            , confirmBudget = min budget.resultCap (max 0 request.limit.unLookupLimit) + 1
            }

{- | The traversal ran out of budget before it could decide anything.

The page carries /no new objects/ and the watermark does not move. That is the only
sound answer, and the reason is the same one that defeats per-branch resumption:
the objects discovered before the interruption are an arbitrary subset of the
result, not its smallest members. Emitting an object @z@ while an unexplored branch
still holds @a@ would advance the watermark past @a@, and the next page -- filtering
to objects strictly greater than @z@ -- would never return it. A gap, silently.

So an interrupted lookup reports 'LookupTruncated' with the cursor it came in with.
The caller retries, with a fresh budget on a fresh request, and makes progress the
moment the budget suffices for one page. A caller whose budget never suffices gets
told so, rather than being handed a plausible, incomplete answer.
-}
interruptedPage :: Maybe LookupCursorState -> ConsistencyToken -> LookupPage
interruptedPage cursorState token =
    LookupPage
        { objects = []
        , state =
            LookupTruncated
                ( encodeLookupCursor
                    LookupCursorState
                        { version = 2
                        , token
                        , lastObject = cursorState >>= (.lastObject)
                        , frontier = []
                        }
                )
        }

{- | The traversal's budget ran out. Raised inside the reverse walk and caught by
'runLookup', which never lets it escape to the caller: it is a paging outcome, not
an error.
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

raiseCheckForCandidate :: CheckForCandidate es -> CheckForCandidate (Error Interrupt : es)
raiseCheckForCandidate candidateCheck =
    CheckForCandidate \graph context revision subject relation object memo ->
        raise (candidateCheck.runCandidateCheck graph context revision subject relation object memo)

{- | What the current page still needs, handed to the /outermost/ confirmation only.

Confirmation is the expensive half of reach-then-check: the reverse walk
over-generates candidates and each one costs a forward check against storage.
Before this existed, every page confirmed every candidate and then threw away the
ones it had already emitted, so page N re-confirmed pages 1..N-1.

'watermark' drops candidates already emitted -- results are sorted by object key, so
anything at or below the watermark has been returned to the client already.
'confirmBudget' stops confirming once the page can be filled: @limit + 1@ allowed
candidates is enough to fill a page of @limit@ /and/ know that more remain.

Both are sound only where the confirmation's output goes straight into the page. A
nested confirmation feeds a further filter upstream, and truncating it could hide
candidates the outer stage would have kept, so nested confirmations receive
'Nothing' and confirm everything.
-}
data EmitWindow = EmitWindow
    { watermark :: !(Maybe ObjectRef)
    , confirmBudget :: !Int
    }

data EvalState = EvalState
    { depth :: !Int
    , visited :: !(Set Subproblem)
    , skipRecursive :: !(Maybe RecursiveStep)
    , budget :: !EvaluationBudget
    }

data Subproblem = Subproblem
    { subject :: !Subject
    , objectType :: !ObjectType
    , relation :: !RelationName
    }
    deriving stock (Eq, Ord, Show)

data RecursiveStep = RecursiveStep
    { tuplesetRelation :: !RelationName
    , computedRelation :: !RelationName
    }
    deriving stock (Eq, Show)

initialState :: EvaluationBudget -> EvalState
initialState budget =
    EvalState{depth = 0, visited = Set.empty, skipRecursive = Nothing, budget}

evalRelation ::
    (TupleStore :> es, Error Interrupt :> es) =>
    Maybe EmitWindow ->
    CheckForCandidate es ->
    Deadline (Eff es) ->
    ReachabilityGraph ->
    CaveatContext ->
    Revision ->
    Subject ->
    ObjectType ->
    RelationName ->
    EvalState ->
    Eff es (Either EnError [LookupObject])
evalRelation window candidateCheck deadline graph context revision subject objectType relation state
    | state.depth >= state.budget.maxDepth =
        pure (Left ResolutionLimitExceeded)
    | Set.member subproblem state.visited && state.skipRecursive == Nothing =
        pure (Right [])
    | otherwise =
        case Map.lookup ref graph.relations of
            Nothing ->
                pure (Left (UnknownRelation (renderRef ref)))
            Just schemaRelation ->
                evalRewrite
                    window
                    candidateCheck
                    deadline
                    graph
                    context
                    revision
                    subject
                    objectType
                    relation
                    schemaRelation.rewrite
                    state{depth = state.depth + 1, visited = Set.insert subproblem state.visited}
  where
    ref = RelationRef{objectType, relation}
    subproblem = Subproblem{subject, objectType, relation}

{- | The emit window rides along a rewrite only where the rewrite's output /is/ the
page's output.

'Union' and 'Caveated' pass it through: a union branch contributes its own smallest
@limit + 1@ candidates, which is enough for the merged page, and a rewrite-level
caveat gates every object identically. 'Intersection' and 'Exclusion' consume it at
their own confirmation but hand 'Nothing' to the sub-rewrites that /produce/ their
candidates, since those must over-generate. 'This', 'ComputedUserset', and arrows
never see it -- a relation reached through them may be an intermediate set, and for
arrows it is used as the /subject/ of a further read, where dropping a low-keyed
object would hide the high-keyed objects it leads to.
-}
evalRewrite ::
    (TupleStore :> es, Error Interrupt :> es) =>
    Maybe EmitWindow ->
    CheckForCandidate es ->
    Deadline (Eff es) ->
    ReachabilityGraph ->
    CaveatContext ->
    Revision ->
    Subject ->
    ObjectType ->
    RelationName ->
    Rewrite ->
    EvalState ->
    Eff es (Either EnError [LookupObject])
evalRewrite window candidateCheck deadline graph context revision subject objectType currentRelation rewrite state =
    case rewrite of
        This ->
            evalThis candidateCheck deadline graph context revision subject objectType currentRelation state
        ComputedUserset relation ->
            evalRelation Nothing candidateCheck deadline graph context revision subject objectType relation state
        TupleToUserset tuplesetRelation computedRelation ->
            evalTupleToUserset candidateCheck deadline graph context revision subject objectType currentRelation tuplesetRelation computedRelation state
        Union rewrites ->
            branches window rewrites
        Intersection rewrites ->
            confirmCandidates window candidateCheck graph context revision subject currentRelation
                =<< branches Nothing rewrites
        Exclusion base _subtractRewrite ->
            confirmCandidates window candidateCheck graph context revision subject currentRelation
                =<< evalRewrite Nothing candidateCheck deadline graph context revision subject objectType currentRelation base state
        Caveated caveat rewriteInner -> do
            inner <- evalRewrite window candidateCheck deadline graph context revision subject objectType currentRelation rewriteInner state
            pure (applyRewriteCaveat graph context caveat =<< inner)
  where
    -- One budget poll per branch. A branch is the coarsest unit of traversal work
    -- that can be skipped whole, and polling any finer costs a clock read per row.
    branches branchWindow rewrites = do
        results <-
            traverse
                ( \current -> do
                    requireBudget deadline
                    evalRewrite branchWindow candidateCheck deadline graph context revision subject objectType currentRelation current state
                )
                rewrites
        pure (mergeLookupObjects . concat <$> sequence results)

evalThis ::
    (TupleStore :> es, Error Interrupt :> es) =>
    CheckForCandidate es ->
    Deadline (Eff es) ->
    ReachabilityGraph ->
    CaveatContext ->
    Revision ->
    Subject ->
    ObjectType ->
    RelationName ->
    EvalState ->
    Eff es (Either EnError [LookupObject])
evalThis candidateCheck deadline graph context revision subject objectType relation state = do
    direct <- readRowsForSubjects state.budget.pageLimit deadline revision objectType relation (subjectsWithWildcard subject)
    case direct of
        Left err -> pure (Left err)
        Right directRows -> do
            usersetRows <- rowsForAllowedUsersets
            let directObjects = catMaybes <$> traverse rowLookupObject directRows
            pure (mergeLookupObjects <$> ((<>) <$> directObjects <*> usersetRows))
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
                                    subjectObjects <- evalRelation Nothing candidateCheck deadline graph context revision subject allowed.objectType subjectRelation state
                                    case subjectObjects of
                                        Left err -> pure (Left err)
                                        Right objects -> do
                                            let subjectSets = [SubjectSet object subjectRelation | LookupObject{object} <- objects]
                                            rows <- readRowsForSubjects state.budget.pageLimit deadline revision objectType relation subjectSets
                                            pure (catMaybes <$> (rows >>= traverse rowLookupObject))
                        )
                        (Set.toAscList relationDefinition.allowedSubjects)
                pure (mergeLookupObjects . concat <$> sequence collected)
    rowLookupObject TupleRow{tuple} =
        fmap (LookupObject tuple.object) <$> includeDecision graph context tuple.caveat Allowed

evalTupleToUserset ::
    (TupleStore :> es, Error Interrupt :> es) =>
    CheckForCandidate es ->
    Deadline (Eff es) ->
    ReachabilityGraph ->
    CaveatContext ->
    Revision ->
    Subject ->
    ObjectType ->
    RelationName ->
    RelationName ->
    RelationName ->
    EvalState ->
    Eff es (Either EnError [LookupObject])
evalTupleToUserset candidateCheck deadline graph context revision subject objectType currentRelation tuplesetRelation computedRelation state
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
                                    usersetObjects <- evalRelation Nothing candidateCheck deadline graph context revision subject allowed.objectType computedRelation state
                                    case usersetObjects of
                                        Left err -> pure (Left err)
                                        Right objects -> do
                                            let subjects = concatMap (subjectsForAllowed allowed) objects
                                            rows <- readRowsForSubjects state.budget.pageLimit deadline revision objectType tuplesetRelation subjects
                                            pure (rows >>= applyRows objects)
                        )
                        (Set.toAscList tuplesetDefinition.allowedSubjects)
                pure (mergeLookupObjects . concat <$> sequence collected)
  where
    recursiveStep = RecursiveStep{tuplesetRelation, computedRelation}
    evalRecursiveUserset allowed = do
        seeds <-
            evalRelation
                Nothing
                candidateCheck
                deadline
                graph
                context
                revision
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
        | depth >= state.budget.maxDepth = pure (Left ResolutionLimitExceeded)
        | null frontier = pure (Right (Map.elems seen))
        | otherwise = do
            -- Each round of the fixpoint is a unit of skippable work, like a branch.
            requireBudget deadline
            rows <- readRowsForSubjects state.budget.pageLimit deadline revision objectType tuplesetRelation (concatMap (subjectsForAllowed allowed) frontier)
            case rows of
                Left err -> pure (Left err)
                Right tupleRows -> do
                    case applyRows frontier tupleRows of
                        Left err -> pure (Left err)
                        Right appliedRows -> do
                            let found = mergeLookupObjects appliedRows
                                seenWithFrontier = insertObjects frontier seen
                                newObjects = filter (\LookupObject{object} -> Map.notMember object seenWithFrontier) found
                            expandRecursive allowed newObjects (insertObjects newObjects seenWithFrontier) (depth + 1)
    applyRows usersetObjects rows =
        let objectDecisionMap =
                Map.fromListWith combineDecisions [(object, decision) | LookupObject{object, decision} <- usersetObjects]
         in fmap concat $
                traverse
                    ( \row@TupleRow{tuple} -> do
                        let usersetDecision =
                                case tuple.subject of
                                    SubjectId subjectObject ->
                                        Just (Map.findWithDefault Allowed subjectObject objectDecisionMap)
                                    SubjectSet subjectObject _ ->
                                        Just (Map.findWithDefault Allowed subjectObject objectDecisionMap)
                                    SubjectWildcard _ ->
                                        Nothing
                        case usersetDecision of
                            Nothing -> Right []
                            Just decision ->
                                includeDecision graph context tuple.caveat decision >>= \case
                                    Nothing -> Right []
                                    Just included -> Right [objectFromRowWithDecision row included]
                    )
                    rows

subjectsWithWildcard :: Subject -> [Subject]
subjectsWithWildcard subject =
    subject
        : case subject of
            SubjectId object -> [SubjectWildcard object.objectType]
            SubjectSet _ _ -> []
            SubjectWildcard _ -> []

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

{- | Confirm over-generated candidates with a forward check at the lookup's pinned
revision.

Given an 'EmitWindow', confirmation costs what the /page/ costs rather than what the
whole candidate set costs. Candidates at or below the watermark were emitted on an
earlier page and are dropped without a check; confirmation then stops as soon as
@limit + 1@ candidates have been allowed, which is exactly enough to fill a page of
@limit@ and still know that more remain. Candidates arrive sorted by object key, so
the ones confirmed are the ones the page wants. Without a window -- a nested
confirmation, whose output is filtered again upstream -- every candidate is
confirmed.

The memo is folded across the candidate list, so subproblems shared between
candidates are evaluated once: confirming twenty objects that all inherit from the
same group reads that group once, not twenty times. It is deliberately not shared
across separate 'confirmCandidates' calls -- a permission with nested intersections
makes several -- because threading it through the whole traversal would mean
restructuring every evaluator to return it. The dominant case is one call with many
candidates.

The memo holds context-free residual decisions, so sharing entries between
candidates cannot leak one candidate's caveat answers into another's: the request
context is applied per candidate, inside 'checkAtRevision'.
-}
confirmCandidates ::
    Maybe EmitWindow ->
    CheckForCandidate es ->
    ReachabilityGraph ->
    CaveatContext ->
    Revision ->
    Subject ->
    RelationName ->
    Either EnError [LookupObject] ->
    Eff es (Either EnError [LookupObject])
confirmCandidates _ _ _ _ _ _ _ (Left err) =
    pure (Left err)
confirmCandidates window candidateCheck graph context revision subject relation (Right candidates) =
    confirmUntilPageFull emptyCheckMemo 0 [] wanted
  where
    wanted =
        case window of
            Nothing -> candidates
            Just EmitWindow{watermark} ->
                case watermark of
                    Nothing -> candidates
                    Just lastSeen -> filter (\LookupObject{object} -> object > lastSeen) candidates

    budgetReached allowedCount =
        case window of
            Nothing -> False
            Just EmitWindow{confirmBudget} -> allowedCount >= confirmBudget

    confirmUntilPageFull memo allowedCount acc remaining
        | budgetReached allowedCount = pure (Right (mergeLookupObjects (reverse acc)))
        | otherwise =
            case remaining of
                [] -> pure (Right (mergeLookupObjects (reverse acc)))
                LookupObject{object} : rest -> do
                    (decision, memo') <- candidateCheck.runCandidateCheck graph context revision subject relation object memo
                    case decision of
                        Left err -> pure (Left err)
                        Right Denied -> confirmUntilPageFull memo' allowedCount acc rest
                        Right allowed -> confirmUntilPageFull memo' (allowedCount + 1) (LookupObject object allowed : acc) rest

{- | Drain every page of a reverse query, polling the caller's budget /between/
store pages.

Between, not before: a relation that fits in one page never polls, so a lookup
small enough to answer always answers. Not per row either -- the poll is an
effectful action, and a clock read per row would cost more than the read it guards.
A page boundary bounds the overshoot at one store round trip.
-}
readRowsForSubjects ::
    (TupleStore :> es, Error Interrupt :> es) =>
    Int ->
    Deadline (Eff es) ->
    Revision ->
    ObjectType ->
    RelationName ->
    [Subject] ->
    Eff es (Either EnError [TupleRow])
readRowsForSubjects _ _ _ _ _ [] =
    pure (Right [])
readRowsForSubjects pageLimit deadline revision objectType relation subjects =
    drain Nothing []
  where
    -- Reversed page accumulation, flattened once. Mirrors the drain loops in
    -- "En.Check" and "En.Expand".
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
        let acc' = page.rows : acc
        case page.state of
            Exhausted -> pure (Right (concat (reverse acc')))
            HasMore next -> continue next acc'
            Truncated next -> continue next acc'

    continue next acc = do
        requireBudget deadline
        drain (Just next) acc

lookupRelation :: ReachabilityGraph -> ObjectType -> RelationName -> Either EnError Relation
lookupRelation graph objectType relation =
    case Map.lookup RelationRef{objectType, relation} graph.relations of
        Just found -> Right found
        Nothing -> Left (UnknownRelation (renderRef RelationRef{objectType, relation}))

objectFromRowWithDecision :: TupleRow -> CheckDecision -> LookupObject
objectFromRowWithDecision TupleRow{tuple} decision =
    LookupObject{object = tuple.object, decision}

includeDecision :: ReachabilityGraph -> CaveatContext -> Maybe TupleCaveat -> CheckDecision -> Either EnError (Maybe CheckDecision)
includeDecision graph context caveat decision = do
    gate <- evaluateTupleCaveat graph context caveat
    case Decision.applyGate gate decision of
        Denied -> Right Nothing
        allowed -> Right (Just allowed)

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
                current{decision = Decision.applyGate gate decision}
            )

combineDecisions :: CheckDecision -> CheckDecision -> CheckDecision
combineDecisions left right =
    Decision.union [left, right]

applyRewriteCaveat :: ReachabilityGraph -> CaveatContext -> CaveatName -> [LookupObject] -> Either EnError [LookupObject]
applyRewriteCaveat graph context caveat objects = do
    gate <- evaluateNamedCaveat graph context caveat (CaveatPayload Map.empty)
    pure (applyGateToObjects gate objects)

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

caveatText :: CaveatName -> Text
caveatText (CaveatName text) =
    text

pageLookup :: (Monad m) => EvaluationBudget -> Deadline m -> LookupLimit -> Maybe LookupCursorState -> ConsistencyToken -> [LookupObject] -> m LookupPage
pageLookup budget deadline (LookupLimit rawLimit) cursorState token objects = do
    hasBudget <- deadline.remainingBudget
    let limit = max 0 rawLimit
        startAfter = cursorState >>= (.lastObject)
        remainingObjects =
            case startAfter of
                Nothing -> objects
                Just lastSeen -> filter (\LookupObject{object} -> object > lastSeen) objects
        visible = take (min budget.resultCap limit) remainingObjects
        hasMore = length visible < length remainingObjects
        nextCursor =
            LookupCursorState
                { version = 2
                , token
                , lastObject = (.object) <$> lastMaybe visible
                , frontier = []
                }
        state
            | hasMore && hasBudget = LookupHasMore (encodeLookupCursor nextCursor)
            | hasMore = LookupTruncated (encodeLookupCursor nextCursor)
            | otherwise = LookupExhausted
    pure LookupPage{objects = visible, state}

lastMaybe :: [a] -> Maybe a
lastMaybe =
    \case
        [] -> Nothing
        values -> Just (last values)

{- | Encode cursor state as opaque text.

Format v2 is the v1 length-prefixed field codec with the raw revision replaced by a
consistency token, and a trailing, variable-length frontier:

@
lookup-v2 |token |lastObjectType |lastObjectId |branchCount ( |type |relation |ordinal |storeCursor |exhausted )*
@

The branch records are appended flat rather than nested inside one field, so no
escaping is needed: the count says how many follow.
-}
encodeLookupCursor :: LookupCursorState -> LookupCursor
encodeLookupCursor LookupCursorState{token, lastObject, frontier} =
    LookupCursor $
        Text.concat
            ( "lookup-v2"
                : encodeField tokenText
                : encodeField (maybe "" (objectText . (.objectType)) lastObject)
                : encodeField (maybe "" (.objectId) lastObject)
                : encodeField (showText (length frontier))
                : concatMap encodeFrontierEntry frontier
            )
  where
    ConsistencyToken tokenText = token

encodeFrontierEntry :: FrontierEntry -> [Text]
encodeFrontierEntry FrontierEntry{branchType, branchRelation, branchOrdinal, branchCursor, branchExhausted} =
    [ encodeField (objectText branchType)
    , encodeField (relationText branchRelation)
    , encodeField (showText branchOrdinal)
    , encodeField (maybe "" (.cursorEncoding) branchCursor)
    , encodeField (if branchExhausted then "1" else "0")
    ]

{- | Parse cursor text. This is /parsing only/ -- it does not validate the embedded
token, and its 'Right' therefore does not mean the cursor may be obeyed. Callers
inside the engine go through 'resolveCursor'.

A @lookup-v1@ cursor is rejected rather than migrated. Its revision field is
precisely the forgeable value v2 exists to remove, so honoring old cursors would
preserve the hole for exactly the clients most likely to be replaying one. Cursors
are short-lived pagination state; a client recovers by restarting the lookup with
no cursor, which is the same recovery path as any invalid cursor.
-}
decodeLookupCursor :: LookupCursor -> Either EnError LookupCursorState
decodeLookupCursor (LookupCursor cursorText) =
    maybe (Left (InvalidConsistencyToken "lookup cursor")) Right do
        body <- Text.stripPrefix "lookup-v2" cursorText
        ([tokenText, objectTypeText, objectId, countText], afterFixed) <- parseFieldsPrefix 4 body
        branchCount <- readMaybe (Text.unpack countText)
        if branchCount < 0 then Nothing else Just ()
        (entries, rest) <- parseFrontier branchCount afterFixed
        if Text.null rest then Just () else Nothing
        pure
            LookupCursorState
                { version = 2
                , token = ConsistencyToken tokenText
                , lastObject =
                    if Text.null objectTypeText && Text.null objectId
                        then Nothing
                        else Just ObjectRef{objectType = ObjectType objectTypeText, objectId}
                , frontier = entries
                }

parseFrontier :: Int -> Text -> Maybe ([FrontierEntry], Text)
parseFrontier 0 rest =
    Just ([], rest)
parseFrontier remaining text = do
    ([typeText, relationName, ordinalText, cursorText, exhaustedText], rest) <- parseFieldsPrefix 5 text
    ordinal <- readMaybe (Text.unpack ordinalText)
    exhausted <-
        case exhaustedText of
            "1" -> Just True
            "0" -> Just False
            _ -> Nothing
    let entry =
            FrontierEntry
                { branchType = ObjectType typeText
                , branchRelation = RelationName relationName
                , branchOrdinal = ordinal
                , branchCursor = if Text.null cursorText then Nothing else Just (StoreCursor cursorText)
                , branchExhausted = exhausted
                }
    (entries, finalRest) <- parseFrontier (remaining - 1) rest
    pure (entry : entries, finalRest)

{- | Parse, then verify, an incoming cursor, returning the snapshot it pins.

A cursor arrives as client text. Its token is decoded and validated by the
datastore exactly as any consistency token presented on a read would be -- same
datastore identity, same schema hash, same garbage-collection horizon -- and the
revision the continuation reads at comes from the /validated/ token metadata,
never from the cursor's own bytes.

A malformed cursor is 'Left' here. A well-formed cursor carrying a token the
datastore rejects raises through the ambient error effect, exactly as
'resolveConsistency' does for a bad 'En.Revision.AtExactSnapshot' token; the two
failures are the same kind of failure and both reach the caller as
'InvalidConsistencyToken'.
-}
resolveCursor ::
    (ConsistencyStore :> es) =>
    LookupCursor ->
    Eff es (Either EnError (Revision, LookupCursorState))
resolveCursor cursor =
    case decodeLookupCursor cursor of
        Left err -> pure (Left err)
        Right cursorState -> do
            metadata <- decodeToken cursorState.token
            validateToken metadata
            pure (Right (metadata.revision, cursorState))

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

objectText :: ObjectType -> Text
objectText (ObjectType text) =
    text

relationText :: RelationName -> Text
relationText (RelationName text) =
    text
