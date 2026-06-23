{-# LANGUAGE DataKinds #-}

module Main (main) where

import Prelude hiding (lookup)

import Data.Map.Strict qualified as Map
import Effectful (Eff, runPureEff)
import Effectful.Error.Static (Error, runErrorNoCallStack)

import Test.Tasty.Bench (bench, bgroup, defaultMain, whnfAppIO)

import En.Check (BatchPair (..), check, checkMany)
import En.Conformance.Kikan (runConsistencyStoreInMemory, runTupleStoreInMemory)
import En.Effect.ConsistencyStore (ConsistencyStore)
import En.Effect.TupleStore (TupleStore)
import En.Error (EnError)
import En.Lookup (LookupLimit (..), LookupRequest (..))
import En.Lookup qualified as Lookup
import En.Reachability (compile)
import En.Revision (Consistency (..))
import En.Schema (ObjectType (..), RelationName (..), Schema)
import En.Schema.Builder qualified as Schema
import En.Tuple (CaveatContext (..), ObjectRef (..), Subject (..), Tuple (..))

main :: IO ()
main = do
    graph <- either (fail . show) pure (compile benchSchema)
    defaultMain
        [ bgroup
            "check"
            [ bench "shallow-owner" $
                whnfAppIO
                    ( \() ->
                        runEngine (check graph MinimizeLatency emptyContext (SubjectId user) (RelationName "view") space)
                    )
                    ()
            , bench "nested-parent" $
                whnfAppIO
                    ( \() ->
                        runEngine (check graph MinimizeLatency emptyContext (SubjectId user) (RelationName "view") childSpace)
                    )
                    ()
            ]
        , bgroup
            "checkMany"
            [ bench "overlapping" $
                whnfAppIO
                    ( \() ->
                        runEngine (checkMany graph MinimizeLatency emptyContext overlappingPairs)
                    )
                    ()
            ]
        , bgroup
            "lookup"
            [ bench "reachable-spaces" $
                whnfAppIO
                    (\() -> runEngine (Lookup.lookup graph MinimizeLatency viewSpacesRequest))
                    ()
            ]
        ]

runEngine :: Eff '[ConsistencyStore, TupleStore, Error EnError] a -> IO (Either EnError a)
runEngine action =
    pure (runPureEff (runErrorNoCallStack (runTupleStoreInMemory benchTuples (runConsistencyStoreInMemory action))))

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
