module Main (main) where

import Prelude hiding (lookup)

import Data.Map.Strict qualified as Map
import Data.Text (Text)
import Data.Text qualified as Text

import Test.Tasty.Bench (bench, bgroup, defaultMain, whnfAppIO)

import En.Check (BatchPair (..), check, checkMany)
import En.Effect.ConsistencyStore (ConsistencyStore (..), ResolvedConsistency (..), TokenMetadata (..))
import En.Effect.TupleStore (PageState (..), StoreCursor (..), TuplePage (..), TupleRow (..), TupleRowId (..), TupleStore (..), UsersetQuery (..))
import En.Lookup (LookupLimit (..), LookupRequest (..))
import En.Lookup qualified as Lookup
import En.Reachability (compile)
import En.Revision (Consistency (..), ConsistencyToken (..), DatastoreId (..), Revision (..), SchemaHash (..))
import En.Schema (ObjectType (..), RelationName (..), Schema)
import En.Schema.Builder qualified as Schema
import En.Tuple (CaveatContext (..), ObjectRef (..), Subject (..), Tuple (..))

main :: IO ()
main = do
    graph <- either (fail . show) pure (compile benchSchema)
    let store = inMemoryTupleStore benchTuples
    defaultMain
        [ bgroup
            "check"
            [ bench "shallow-owner" $
                whnfAppIO
                    ( \() ->
                        check consistencyStore store graph MinimizeLatency emptyContext (SubjectId user) (RelationName "view") space
                    )
                    ()
            , bench "nested-parent" $
                whnfAppIO
                    ( \() ->
                        check consistencyStore store graph MinimizeLatency emptyContext (SubjectId user) (RelationName "view") childSpace
                    )
                    ()
            ]
        , bgroup
            "checkMany"
            [ bench "overlapping" $
                whnfAppIO
                    ( \() ->
                        checkMany consistencyStore store graph MinimizeLatency emptyContext overlappingPairs
                    )
                    ()
            ]
        , bgroup
            "lookup"
            [ bench "reachable-spaces" $
                whnfAppIO
                    (\() -> Lookup.lookup consistencyStore store graph MinimizeLatency viewSpacesRequest)
                    ()
            ]
        ]

benchSchema :: Schema
benchSchema =
    Schema.build
        [ Schema.object "user" []
        , Schema.object
            "space"
            [ Schema.relation "owner" [Schema.subject "user"] Schema.this
            , Schema.relation "parent" [Schema.subject "space"] Schema.this
            , Schema.permission "view" (Schema.anyOf (Schema.computed "owner") [Schema.arrow "parent" "view"])
            ]
        ]

benchTuples :: [Tuple]
benchTuples =
    [ Tuple space (RelationName "owner") (SubjectId user) Nothing
    , Tuple childSpace (RelationName "parent") (SubjectId space) Nothing
    ]

viewSpacesRequest :: LookupRequest
viewSpacesRequest =
    LookupRequest
        { subject = SubjectId user
        , permission = RelationName "view"
        , objectType = space.objectType
        , context = emptyContext
        , limit = LookupLimit 50
        , cursor = Nothing
        }

overlappingPairs :: [BatchPair]
overlappingPairs =
    [ BatchPair (SubjectId user) (RelationName "view") space
    , BatchPair (SubjectId user) (RelationName "owner") space
    , BatchPair (SubjectId user) (RelationName "view") childSpace
    ]

emptyContext :: CaveatContext
emptyContext =
    CaveatContext Map.empty

user :: ObjectRef
user =
    ObjectRef (ObjectType "user") "alice"

space :: ObjectRef
space =
    ObjectRef (ObjectType "space") "project"

childSpace :: ObjectRef
childSpace =
    ObjectRef (ObjectType "space") "child"

testRevision :: Revision
testRevision =
    Revision "1:2:"

consistencyStore :: ConsistencyStore IO
consistencyStore =
    ConsistencyStore
        { decodeToken = \token ->
            pure (Right (TokenMetadata token testRevision (DatastoreId "bench") (SchemaHash "schema") Nothing))
        , validateToken = \_ -> pure (Right ())
        , resolveConsistency = \consistency ->
            pure (Right ResolvedConsistency{consistency, revision = testRevision})
        }

inMemoryTupleStore :: [Tuple] -> TupleStore IO
inMemoryTupleStore tuples =
    TupleStore
        { readObjectRelation = \_ object relation limit cursor ->
            pure (pageTuples limit cursor [tuple | tuple <- tuples, tuple.object == object, tuple.relation == relation])
        , readStartingWithUser = \_ query ->
            pure
                ( pageTuples
                    query.queryLimit
                    query.queryCursor
                    [ tuple
                    | tuple <- tuples
                    , tuple.object.objectType == query.queryType
                    , tuple.relation == query.queryRelation
                    , tuple.subject `elem` query.querySubjects
                    ]
                )
        , writeTuples = \_ -> pure (ConsistencyToken "bench-write")
        , deleteTuples = \_ -> pure (ConsistencyToken "bench-delete")
        , headRevision = pure testRevision
        , optimizedRevision = pure testRevision
        , oldestRetainedXid = pure 0
        , reapDeletedTuples = \_ -> pure 0
        }

pageTuples :: Int -> Maybe StoreCursor -> [Tuple] -> TuplePage
pageTuples limit cursor tuples =
    let start = maybe 0 decodeCursor cursor
        indexed = drop start (zip [start + 1 ..] tuples)
        (visible, extra) = splitAt (max 0 limit) indexed
        rows = uncurry tupleRow <$> visible
        state =
            case extra of
                [] -> Exhausted
                _ ->
                    let cursorIndex =
                            case visible of
                                [] -> start
                                visibleRows -> fst (last visibleRows)
                     in HasMore (StoreCursor (showText cursorIndex))
     in TuplePage{rows, state}

tupleRow :: Int -> Tuple -> TupleRow
tupleRow index tuple =
    TupleRow
        { rowId = TupleRowId (showText index)
        , tuple
        , createdAt = testRevision
        , deletedAt = Nothing
        }

decodeCursor :: StoreCursor -> Int
decodeCursor (StoreCursor cursorText) =
    case reads (Text.unpack cursorText) of
        [(value, "")] -> value
        _ -> 0

showText :: (Show a) => a -> Text
showText =
    Text.pack . show
