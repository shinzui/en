{-# LANGUAGE NoFieldSelectors #-}

{- | Forward expansion for review and audit UIs.

Expand answers "who can reach this object relation?" as a bounded tree. Later
plans fill in traversal; this plan fixes the public result shape.
-}
module En.Expand (
    ExpandCursor (..),
    ExpandLimit (..),
    ExpandRequest (..),
    ExpandState (..),
    ExpandNode (..),
    ExpandTree (..),
    expand,
) where

import Data.Map.Strict qualified as Map
import Data.Text (Text)
import Data.Text qualified as Text

import En.Effect.ConsistencyStore (ConsistencyStore (..), ResolvedConsistency (..))
import En.Effect.TupleStore (PageState (..), StoreCursor, TuplePage (..), TupleRow (..), TupleStore (..))
import En.Error (EnError (..))
import En.Reachability (ReachabilityGraph (..), RelationRef (..))
import En.Revision (Consistency, Revision)
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
    { object :: !ObjectRef
    , permission :: !RelationName
    , context :: !CaveatContext
    , limit :: !ExpandLimit
    , cursor :: !(Maybe ExpandCursor)
    }
    deriving stock (Eq, Show)

data ExpandState
    = ExpandExhausted
    | ExpandHasMore !ExpandCursor
    | ExpandTruncated !ExpandCursor
    deriving stock (Eq, Ord, Show)

data ExpandNode
    = ExpandSubject !Subject !(Maybe TupleRow)
    | ExpandUserset !ObjectRef !RelationName ![ExpandNode]
    | ExpandCaveated !CaveatName ![ExpandNode]
    deriving stock (Eq, Show)

data ExpandTree = ExpandTree
    { root :: !ObjectRef
    , permission :: !RelationName
    , children :: ![ExpandNode]
    , state :: !ExpandState
    }
    deriving stock (Eq, Show)

expand ::
    (Monad m) =>
    ConsistencyStore m ->
    TupleStore m ->
    ReachabilityGraph ->
    Consistency ->
    ExpandRequest ->
    m (Either EnError ExpandTree)
expand consistencyStore tupleStore graph consistency request = do
    resolved <- consistencyStore.resolveConsistency consistency
    case resolved of
        Left err -> pure (Left err)
        Right ResolvedConsistency{revision} ->
            runExpand tupleStore graph revision request

runExpand ::
    (Monad m) =>
    TupleStore m ->
    ReachabilityGraph ->
    Revision ->
    ExpandRequest ->
    m (Either EnError ExpandTree)
runExpand tupleStore graph revision request = do
    children <- expandRelation tupleStore graph revision request.object request.permission initialState
    pure $
        ( \nodes ->
            let (visible, state) = pageNodes request.limit request.cursor nodes
             in ExpandTree
                    { root = request.object
                    , permission = request.permission
                    , children = visible
                    , state
                    }
        )
            <$> children

data EvalState = EvalState
    { depth :: !Int
    , visited :: ![Subproblem]
    }

data Subproblem = Subproblem
    { object :: !ObjectRef
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

resultCap :: Int
resultCap = 1000

expandRelation ::
    (Monad m) =>
    TupleStore m ->
    ReachabilityGraph ->
    Revision ->
    ObjectRef ->
    RelationName ->
    EvalState ->
    m (Either EnError [ExpandNode])
expandRelation tupleStore graph revision object relation state
    | state.depth >= maxDepth =
        pure (Left ResolutionLimitExceeded)
    | subproblem `elem` state.visited =
        pure (Left ResolutionLimitExceeded)
    | otherwise =
        case lookupRelation graph object.objectType relation of
            Left err -> pure (Left err)
            Right schemaRelation ->
                expandRewrite
                    tupleStore
                    graph
                    revision
                    object
                    relation
                    schemaRelation.rewrite
                    EvalState{depth = state.depth + 1, visited = subproblem : state.visited}
  where
    subproblem = Subproblem{object, relation}

expandRewrite ::
    (Monad m) =>
    TupleStore m ->
    ReachabilityGraph ->
    Revision ->
    ObjectRef ->
    RelationName ->
    Rewrite ->
    EvalState ->
    m (Either EnError [ExpandNode])
expandRewrite tupleStore graph revision object currentRelation rewrite state =
    case rewrite of
        This ->
            expandThis tupleStore graph revision object currentRelation state
        ComputedUserset relation -> do
            children <- expandRelation tupleStore graph revision object relation state
            pure (fmap (pure . ExpandUserset object relation) children)
        TupleToUserset tuplesetRelation computedRelation ->
            expandTupleToUserset tupleStore graph revision object tuplesetRelation computedRelation state
        Union rewrites -> do
            children <- traverse (\current -> expandRewrite tupleStore graph revision object currentRelation current state) rewrites
            pure (concat <$> sequence children)
        Intersection rewrites -> do
            children <- traverse (\current -> expandRewrite tupleStore graph revision object currentRelation current state) rewrites
            pure (concat <$> sequence children)
        Exclusion base subtractRewrite -> do
            baseChildren <- expandRewrite tupleStore graph revision object currentRelation base state
            subtractChildren <- expandRewrite tupleStore graph revision object currentRelation subtractRewrite state
            pure ((<>) <$> baseChildren <*> subtractChildren)
        Caveated caveat rewriteInner -> do
            children <- expandRewrite tupleStore graph revision object currentRelation rewriteInner state
            pure (pure . ExpandCaveated caveat <$> children)

expandThis ::
    (Monad m) =>
    TupleStore m ->
    ReachabilityGraph ->
    Revision ->
    ObjectRef ->
    RelationName ->
    EvalState ->
    m (Either EnError [ExpandNode])
expandThis tupleStore graph revision object relation state = do
    rows <- readObjectRows tupleStore revision object relation
    case rows of
        Left err -> pure (Left err)
        Right tupleRows -> do
            nodes <- traverse (nodeFromRow tupleStore graph revision state) tupleRows
            pure $
                case sequence nodes of
                    Left err -> Left err
                    Right expanded -> Right (concat expanded)

expandTupleToUserset ::
    (Monad m) =>
    TupleStore m ->
    ReachabilityGraph ->
    Revision ->
    ObjectRef ->
    RelationName ->
    RelationName ->
    EvalState ->
    m (Either EnError [ExpandNode])
expandTupleToUserset tupleStore graph revision object tuplesetRelation computedRelation state = do
    rows <- readObjectRows tupleStore revision object tuplesetRelation
    case rows of
        Left err -> pure (Left err)
        Right tupleRows -> do
            nodes <- traverse expandRow tupleRows
            pure $
                case sequence nodes of
                    Left err -> Left err
                    Right expanded -> Right (concat expanded)
  where
    expandRow row@TupleRow{tuple} =
        case tuple.subject of
            SubjectId subjectObject ->
                usersetNode row subjectObject computedRelation
            SubjectSet subjectObject subjectRelation ->
                usersetNode row subjectObject subjectRelation
            SubjectWildcard subjectType ->
                pure (Right (wrapTupleCaveat tuple.caveat [ExpandSubject (SubjectWildcard subjectType) (Just row)]))
    usersetNode TupleRow{tuple} subjectObject relation = do
        children <- expandRelation tupleStore graph revision subjectObject relation state
        pure (wrapTupleCaveat tuple.caveat . pure . ExpandUserset subjectObject relation <$> children)

nodeFromRow ::
    (Monad m) =>
    TupleStore m ->
    ReachabilityGraph ->
    Revision ->
    EvalState ->
    TupleRow ->
    m (Either EnError [ExpandNode])
nodeFromRow tupleStore graph revision state row@TupleRow{tuple} =
    case tuple.subject of
        SubjectId subject ->
            pure (Right (wrapTupleCaveat tuple.caveat [ExpandSubject (SubjectId subject) (Just row)]))
        SubjectSet subject relation -> do
            children <- expandRelation tupleStore graph revision subject relation state
            pure (wrapTupleCaveat tuple.caveat . pure . ExpandUserset subject relation <$> children)
        SubjectWildcard subjectType ->
            pure (Right (wrapTupleCaveat tuple.caveat [ExpandSubject (SubjectWildcard subjectType) (Just row)]))

wrapTupleCaveat :: Maybe TupleCaveat -> [ExpandNode] -> [ExpandNode]
wrapTupleCaveat Nothing nodes = nodes
wrapTupleCaveat (Just TupleCaveat{name}) nodes = [ExpandCaveated name nodes]

readObjectRows ::
    (Monad m) =>
    TupleStore m ->
    Revision ->
    ObjectRef ->
    RelationName ->
    m (Either EnError [TupleRow])
readObjectRows tupleStore revision object relation = do
    page <- tupleStore.readObjectRelation revision object relation pageLimit Nothing
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

pageNodes :: ExpandLimit -> Maybe ExpandCursor -> [ExpandNode] -> ([ExpandNode], ExpandState)
pageNodes (ExpandLimit rawLimit) cursor nodes =
    let limit = max 0 rawLimit
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
renderRef RelationRef{objectType = ObjectType objectType, relation = RelationName relation} =
    objectType <> "#" <> relation
