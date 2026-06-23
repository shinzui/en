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
import Effectful (Eff, (:>))
import Effectful.Error.Static (Error, throwError)

import En.Effect.ConsistencyStore (ConsistencyStore, ResolvedConsistency (..), resolveConsistency)
import En.Effect.TupleStore (PageState (..), TuplePage (..), TupleRow (..), TupleStore, readObjectRelation)
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
    (ConsistencyStore :> es, TupleStore :> es, Error EnError :> es) =>
    ReachabilityGraph ->
    Consistency ->
    ExpandRequest ->
    Eff es ExpandTree
expand graph consistency request = do
    ResolvedConsistency{revision} <- resolveConsistency consistency
    either throwError pure =<< runExpand graph revision request

runExpand ::
    (TupleStore :> es) =>
    ReachabilityGraph ->
    Revision ->
    ExpandRequest ->
    Eff es (Either EnError ExpandTree)
runExpand graph revision request = do
    children <- expandRelation graph revision request.object request.permission initialState
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
    (TupleStore :> es) =>
    ReachabilityGraph ->
    Revision ->
    ObjectRef ->
    RelationName ->
    EvalState ->
    Eff es (Either EnError [ExpandNode])
expandRelation graph revision object relation state
    | state.depth >= maxDepth =
        pure (Left ResolutionLimitExceeded)
    | subproblem `elem` state.visited =
        pure (Left ResolutionLimitExceeded)
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
                    EvalState{depth = state.depth + 1, visited = subproblem : state.visited}
  where
    subproblem = Subproblem{object, relation}

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
            children <- traverse (\current -> expandRewrite graph revision object currentRelation current state) rewrites
            pure (concat <$> sequence children)
        Intersection rewrites -> do
            children <- traverse (\current -> expandRewrite graph revision object currentRelation current state) rewrites
            pure (concat <$> sequence children)
        Exclusion base subtractRewrite -> do
            baseChildren <- expandRewrite graph revision object currentRelation base state
            subtractChildren <- expandRewrite graph revision object currentRelation subtractRewrite state
            pure ((<>) <$> baseChildren <*> subtractChildren)
        Caveated caveat rewriteInner -> do
            children <- expandRewrite graph revision object currentRelation rewriteInner state
            pure (pure . ExpandCaveated caveat <$> children)

expandThis ::
    (TupleStore :> es) =>
    ReachabilityGraph ->
    Revision ->
    ObjectRef ->
    RelationName ->
    EvalState ->
    Eff es (Either EnError [ExpandNode])
expandThis graph revision object relation state = do
    rows <- readObjectRows revision object relation
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
    rows <- readObjectRows revision object tuplesetRelation
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
        children <- expandRelation graph revision subjectObject relation state
        pure (wrapTupleCaveat tuple.caveat . pure . ExpandUserset subjectObject relation <$> children)

nodeFromRow ::
    (TupleStore :> es) =>
    ReachabilityGraph ->
    Revision ->
    EvalState ->
    TupleRow ->
    Eff es (Either EnError [ExpandNode])
nodeFromRow graph revision state row@TupleRow{tuple} =
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
wrapTupleCaveat (Just TupleCaveat{name}) nodes = [ExpandCaveated name nodes]

readObjectRows ::
    (TupleStore :> es) =>
    Revision ->
    ObjectRef ->
    RelationName ->
    Eff es (Either EnError [TupleRow])
readObjectRows revision object relation =
    drain Nothing []
  where
    drain cursor acc = do
        page <- readObjectRelation revision object relation pageLimit cursor
        case page.state of
            Exhausted -> pure (Right (acc <> page.rows))
            HasMore next -> drain (Just next) (acc <> page.rows)
            Truncated next -> drain (Just next) (acc <> page.rows)

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
