{-# LANGUAGE NoFieldSelectors #-}

-- | Forward expansion for review and audit UIs.
--
-- Expand answers "who can reach this object relation?" as a bounded tree. Later
-- plans fill in traversal; this plan fixes the public result shape.
module En.Expand
  ( ExpandCursor (..),
    ExpandLimit (..),
    ExpandRequest (..),
    ExpandState (..),
    ExpandNode (..),
    ExpandTree (..),
    expand,
    expandWithBudget,
  )
where

import Data.Map.Strict qualified as Map
import Data.Set (Set)
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text qualified as Text
import Effectful (Eff, (:>))
import Effectful.Error.Static (Error, throwError)
import En.Budget (EvaluationBudget (..), defaultEvaluationBudget)
import En.Effect.ConsistencyStore (ConsistencyStore, ResolvedConsistency (..), mintToken, resolveConsistency)
import En.Effect.TupleStore (PageState (..), TuplePage (..), TupleRow (..), TupleStore, readObjectRelation)
import En.Error (EnError (..))
import En.Reachability (ReachabilityGraph (..), RelationRef (..))
import En.Revision (Consistency, ConsistencyToken, Revision)
import En.Schema (CaveatName, ObjectType (..), Relation (..), RelationName (..), Rewrite (..))
import En.Tuple (CaveatContext, ObjectRef (..), Subject (..), Tuple (..), TupleCaveat (..))

newtype ExpandCursor = ExpandCursor
  { cursorEncoding :: Text
  }
  deriving stock (Eq, Ord, Show)

newtype ExpandLimit = ExpandLimit
  { unExpandLimit :: Int
  }
  deriving stock (Eq, Ord, Show)

data ExpandRequest = ExpandRequest
  { object :: !ObjectRef,
    permission :: !RelationName,
    context :: !CaveatContext,
    limit :: !ExpandLimit,
    cursor :: !(Maybe ExpandCursor)
  }
  deriving stock (Eq, Show)

data ExpandState
  = ExpandExhausted
  | ExpandHasMore !ExpandCursor
  | ExpandTruncated !ExpandCursor
  deriving stock (Eq, Ord, Show)

-- | A node of the expansion tree.
--
-- Two constructors carry data: 'ExpandSubject' is a leaf naming a concrete subject, and
-- 'ExpandUserset' names a subtree — everyone holding @relation@ on @object@, expanded below.
--
-- The other four are wrappers over child lists, and they form one family: each says how its
-- children combine. 'ExpandCaveated' is the caveat gate that has always been here; the three
-- set operators say what the tree used to leave implicit. An auditor reading a flat child
-- list cannot tell "all of these" from "any of these" from "these, except those", which is
-- why the operators are part of the answer rather than decoration.
data ExpandNode
  = -- | A concrete subject, with the tuple row that grants it.
    ExpandSubject !Subject !(Maybe TupleRow)
  | -- | Everyone holding the relation on the object, expanded below.
    ExpandUserset !ObjectRef !RelationName ![ExpandNode]
  | -- | Caveat gate: the children grant only when the named caveat passes.
    ExpandCaveated !CaveatName ![ExpandNode]
  | -- | Any one child suffices.
    ExpandUnion ![ExpandNode]
  | -- | Every child is required. One child per conjunct.
    ExpandIntersection ![ExpandNode]
  | -- | The first list grants; the second subtracts from it.
    ExpandExclusion ![ExpandNode] ![ExpandNode]
  deriving stock (Eq, Show)

-- | An expansion, and the snapshot it was taken at.
--
-- 'checkedAt' pins the revision 'expand' resolved. An auditor reading this tree can
-- name the moment it describes, and re-read at @AtLeastAsFresh@ that token to
-- compare against a later one.
data ExpandTree = ExpandTree
  { root :: !ObjectRef,
    permission :: !RelationName,
    children :: ![ExpandNode],
    state :: !ExpandState,
    checkedAt :: !ConsistencyToken
  }
  deriving stock (Eq, Show)

expand ::
  (ConsistencyStore :> es, TupleStore :> es, Error EnError :> es) =>
  ReachabilityGraph ->
  Consistency ->
  ExpandRequest ->
  Eff es ExpandTree
expand =
  expandWithBudget defaultEvaluationBudget

-- | 'expand' under caller-chosen evaluation bounds. See "En.Budget".
expandWithBudget ::
  (ConsistencyStore :> es, TupleStore :> es, Error EnError :> es) =>
  EvaluationBudget ->
  ReachabilityGraph ->
  Consistency ->
  ExpandRequest ->
  Eff es ExpandTree
expandWithBudget budget graph consistency request = do
  ResolvedConsistency {revision} <- resolveConsistency consistency
  checkedAt <- mintToken revision
  either throwError pure =<< runExpand budget graph revision checkedAt request

runExpand ::
  (TupleStore :> es) =>
  EvaluationBudget ->
  ReachabilityGraph ->
  Revision ->
  ConsistencyToken ->
  ExpandRequest ->
  Eff es (Either EnError ExpandTree)
runExpand budget graph revision checkedAt request = do
  children <- expandRelation graph revision request.object request.permission (initialState budget)
  pure $
    ( \nodes ->
        let (visible, state) = pageNodes budget request.limit request.cursor nodes
         in ExpandTree
              { root = request.object,
                permission = request.permission,
                children = visible,
                state,
                checkedAt
              }
    )
      <$> children

data EvalState = EvalState
  { depth :: !Int,
    visited :: !(Set Subproblem),
    budget :: !EvaluationBudget
  }

data Subproblem = Subproblem
  { object :: !ObjectRef,
    relation :: !RelationName
  }
  deriving stock (Eq, Ord, Show)

initialState :: EvaluationBudget -> EvalState
initialState budget =
  EvalState {depth = 0, visited = Set.empty, budget}

expandRelation ::
  (TupleStore :> es) =>
  ReachabilityGraph ->
  Revision ->
  ObjectRef ->
  RelationName ->
  EvalState ->
  Eff es (Either EnError [ExpandNode])
-- Unlike check and lookup, expand reports a cycle rather than treating it as an
-- empty result: it renders a tree for a human to audit, and quietly dropping a
-- cyclic branch would hide data from the reviewer.
expandRelation graph revision object relation state
  | state.depth >= state.budget.maxDepth =
      pure (Left ResolutionLimitExceeded)
  | Set.member subproblem state.visited =
      pure (Left (CycleDetected (renderSubproblem subproblem)))
  | otherwise =
      case lookupRelation graph object.objectType relation of
        Left err -> pure (Left err)
        Right schemaRelation ->
          expandRewrite
            graph
            revision
            object
            relation
            schemaRelation.rewrite
            state {depth = state.depth + 1, visited = Set.insert subproblem state.visited}
  where
    subproblem = Subproblem {object, relation}

expandRewrite ::
  (TupleStore :> es) =>
  ReachabilityGraph ->
  Revision ->
  ObjectRef ->
  RelationName ->
  Rewrite ->
  EvalState ->
  Eff es (Either EnError [ExpandNode])
expandRewrite graph revision object currentRelation rewrite state =
  case rewrite of
    This ->
      expandThis graph revision object currentRelation state
    ComputedUserset relation -> do
      children <- expandRelation graph revision object relation state
      pure (fmap (pure . ExpandUserset object relation) children)
    TupleToUserset tuplesetRelation computedRelation ->
      expandTupleToUserset graph revision object tuplesetRelation computedRelation state
    Union rewrites -> do
      branches <- traverse (\current -> expandRewrite graph revision object currentRelation current state) rewrites
      pure (unionNode <$> sequence branches)
    Intersection rewrites -> do
      branches <- traverse (\current -> expandRewrite graph revision object currentRelation current state) rewrites
      pure (intersectionNode <$> sequence branches)
    Exclusion base subtractRewrite -> do
      baseChildren <- expandRewrite graph revision object currentRelation base state
      subtractChildren <- expandRewrite graph revision object currentRelation subtractRewrite state
      pure ((\granted subtracted -> [ExpandExclusion granted subtracted]) <$> baseChildren <*> subtractChildren)
    Caveated caveat rewriteInner -> do
      children <- expandRewrite graph revision object currentRelation rewriteInner state
      pure (pure . ExpandCaveated caveat <$> children)

-- | Combine a union's expanded branches into the caller's node list.
--
-- A one-branch union says nothing the branch does not already say, so it collapses. Beyond
-- that the branches merge: inside a union, a branch boundary carries no information an
-- auditor can use, because any member of any branch grants on its own.
unionNode :: [[ExpandNode]] -> [ExpandNode]
unionNode [single] = single
unionNode branches = [ExpandUnion (concat branches)]

-- | Combine an intersection's expanded branches into the caller's node list.
--
-- Branch boundaries here are precisely what the old flattening destroyed, so each conjunct
-- survives as one child: @n@ conjuncts in, @n@ children out. Concatenating them instead —
-- as this evaluator once did — turns "owner /and/ member" into a pile of subjects
-- indistinguishable from "owner /or/ member". A one-branch intersection collapses, as a
-- one-branch union does.
intersectionNode :: [[ExpandNode]] -> [ExpandNode]
intersectionNode [single] = single
intersectionNode branches = [ExpandIntersection (asBranchNode <$> branches)]

-- | Reduce one branch's expansion to the single node standing for that branch.
--
-- A branch expanding to several nodes is union-shaped — any one of its rows grants the
-- branch — so it wraps in 'ExpandUnion'. A branch expanding to none becomes an empty union,
-- which grants nobody: that is a faithful conjunct and must not be dropped, because it is
-- the reason the intersection denies.
asBranchNode :: [ExpandNode] -> ExpandNode
asBranchNode [single] = single
asBranchNode nodes = ExpandUnion nodes

expandThis ::
  (TupleStore :> es) =>
  ReachabilityGraph ->
  Revision ->
  ObjectRef ->
  RelationName ->
  EvalState ->
  Eff es (Either EnError [ExpandNode])
expandThis graph revision object relation state = do
  rows <- readObjectRows state.budget.pageLimit revision object relation
  case rows of
    Left err -> pure (Left err)
    Right tupleRows -> do
      nodes <- traverse (nodeFromRow graph revision state) tupleRows
      pure $
        case sequence nodes of
          Left err -> Left err
          Right expanded -> Right (concat expanded)

expandTupleToUserset ::
  (TupleStore :> es) =>
  ReachabilityGraph ->
  Revision ->
  ObjectRef ->
  RelationName ->
  RelationName ->
  EvalState ->
  Eff es (Either EnError [ExpandNode])
expandTupleToUserset graph revision object tuplesetRelation computedRelation state = do
  rows <- readObjectRows state.budget.pageLimit revision object tuplesetRelation
  case rows of
    Left err -> pure (Left err)
    Right tupleRows -> do
      nodes <- traverse expandRow tupleRows
      pure $
        case sequence nodes of
          Left err -> Left err
          Right expanded -> Right (concat expanded)
  where
    expandRow row@TupleRow {tuple} =
      case tuple.subject of
        SubjectId subjectObject ->
          usersetNode row subjectObject computedRelation
        SubjectSet subjectObject subjectRelation ->
          usersetNode row subjectObject subjectRelation
        SubjectWildcard subjectType ->
          pure (Right (wrapTupleCaveat tuple.caveat [ExpandSubject (SubjectWildcard subjectType) (Just row)]))
    usersetNode TupleRow {tuple} subjectObject relation = do
      children <- expandRelation graph revision subjectObject relation state
      pure (wrapTupleCaveat tuple.caveat . pure . ExpandUserset subjectObject relation <$> children)

nodeFromRow ::
  (TupleStore :> es) =>
  ReachabilityGraph ->
  Revision ->
  EvalState ->
  TupleRow ->
  Eff es (Either EnError [ExpandNode])
nodeFromRow graph revision state row@TupleRow {tuple} =
  case tuple.subject of
    SubjectId subject ->
      pure (Right (wrapTupleCaveat tuple.caveat [ExpandSubject (SubjectId subject) (Just row)]))
    SubjectSet subject relation -> do
      children <- expandRelation graph revision subject relation state
      pure (wrapTupleCaveat tuple.caveat . pure . ExpandUserset subject relation <$> children)
    SubjectWildcard subjectType ->
      pure (Right (wrapTupleCaveat tuple.caveat [ExpandSubject (SubjectWildcard subjectType) (Just row)]))

wrapTupleCaveat :: Maybe TupleCaveat -> [ExpandNode] -> [ExpandNode]
wrapTupleCaveat Nothing nodes = nodes
wrapTupleCaveat (Just TupleCaveat {name}) nodes = [ExpandCaveated name nodes]

readObjectRows ::
  (TupleStore :> es) =>
  Int ->
  Revision ->
  ObjectRef ->
  RelationName ->
  Eff es (Either EnError [TupleRow])
readObjectRows pageLimit revision object relation =
  drain Nothing []
  where
    -- Reversed page accumulation, flattened once. Mirrors the drain loops in
    -- "En.Check" and "En.Lookup".
    drain cursor acc = do
      page <- readObjectRelation revision object relation pageLimit cursor
      let acc' = page.rows : acc
      case page.state of
        Exhausted -> pure (Right (concat (reverse acc')))
        HasMore next -> drain (Just next) acc'
        Truncated next -> drain (Just next) acc'

lookupRelation :: ReachabilityGraph -> ObjectType -> RelationName -> Either EnError Relation
lookupRelation graph objectType relation =
  case Map.lookup RelationRef {objectType, relation} graph.relations of
    Just found -> Right found
    Nothing -> Left (UnknownRelation (renderRef RelationRef {objectType, relation}))

pageNodes :: EvaluationBudget -> ExpandLimit -> Maybe ExpandCursor -> [ExpandNode] -> ([ExpandNode], ExpandState)
pageNodes budget (ExpandLimit rawLimit) cursor nodes =
  let resultCap = budget.resultCap
      limit = max 0 rawLimit
      start = maybe 0 decodeCursor cursor
      capped = take resultCap nodes
      visible = take limit (drop start capped)
      next = start + length visible
      state
        | next < length capped = ExpandHasMore (ExpandCursor (showText next))
        | length nodes > resultCap = ExpandTruncated (ExpandCursor (showText resultCap))
        | otherwise = ExpandExhausted
   in (visible, state)

decodeCursor :: ExpandCursor -> Int
decodeCursor (ExpandCursor cursorText) =
  case reads (Text.unpack cursorText) of
    [(value, "")] -> max 0 value
    _ -> 0

showText :: (Show a) => a -> Text
showText =
  Text.pack . show

renderRef :: RelationRef -> Text
renderRef RelationRef {objectType = ObjectType objectType, relation = RelationName relation} =
  objectType <> "#" <> relation

-- | Render a revisited subproblem as @"space:recursive#view"@ for 'CycleDetected'.
renderSubproblem :: Subproblem -> Text
renderSubproblem Subproblem {object = ObjectRef {objectType = ObjectType objectType, objectId}, relation = RelationName relation} =
  objectType <> ":" <> objectId <> "#" <> relation
