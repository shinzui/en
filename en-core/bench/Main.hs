{-# LANGUAGE DataKinds #-}

module Main (main) where

import Prelude hiding (lookup)

import Data.Map.Strict qualified as Map
import Data.Text qualified as Text
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
import En.Reachability (compileSchema)
import En.Revision (Consistency (..))
import En.Schema (ObjectType (..), RelationName (..), Schema)
import En.Schema.Builder qualified as Schema
import En.Tuple (CaveatContext (..), ObjectRef (..), Subject (..), Tuple (..))

main :: IO ()
main = do
    graph <- either (fail . show) pure (compileSchema benchSchema)
    wideGraph <- either (fail . show) pure (compileSchema wideSchema)
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
        , -- Before the point-membership probe landed, neither of these ran at all:
          -- a relation wider than one 1000-row page failed the check with
          -- ResolutionLimitExceeded. The first numbers recorded here are therefore
          -- the baseline for docs/plans/44 to improve on, not a regression target.
          bgroup
            "check-wide"
            [ bench "direct-member" $
                whnfAppIO
                    ( \() ->
                        runWideEngine (check wideGraph MinimizeLatency emptyContext (SubjectId wideMember) (RelationName "viewer") wideFolder)
                    )
                    ()
            , bench "non-member" $
                whnfAppIO
                    ( \() ->
                        runWideEngine (check wideGraph MinimizeLatency emptyContext (SubjectId outsider) (RelationName "viewer") wideFolder)
                    )
                    ()
            ]
        ]

runEngine :: Eff '[ConsistencyStore, TupleStore, Error EnError] a -> IO (Either EnError a)
runEngine action =
    pure (runPureEff (runErrorNoCallStack (runTupleStoreInMemory benchTuples (runConsistencyStoreInMemory action))))

runWideEngine :: Eff '[ConsistencyStore, TupleStore, Error EnError] a -> IO (Either EnError a)
runWideEngine action =
    pure (runPureEff (runErrorNoCallStack (runTupleStoreInMemory wideTuples (runConsistencyStoreInMemory action))))

benchSchema :: Schema
benchSchema =
    either (error . ("invalid benchmark schema fixture: " <>) . show) id $ do
        userObject <- Schema.object "user" []
        spaceObject <-
            Schema.object
                "space"
                [ Schema.relation "owner" [Schema.subject "user"] Schema.this
                , Schema.relation "parent" [Schema.subject "space"] Schema.this
                , Schema.permission "view" (Schema.anyOf (Schema.computed "owner") [Schema.arrow "parent" "view"])
                ]
        Schema.build [userObject, spaceObject]

benchTuples :: [Tuple]
benchTuples =
    [ Tuple space (RelationName "owner") (SubjectId user) Nothing
    , Tuple childSpace (RelationName "parent") (SubjectId space) Nothing
    ]

{- | One folder with 2048 direct viewers: a relation two pages wider than the
1000-row read page, used to show that a membership check costs a bounded probe
rather than work proportional to the relation's width.
-}
wideSchema :: Schema
wideSchema =
    either (error . ("invalid wide benchmark schema fixture: " <>) . show) id $ do
        userObject <- Schema.object "user" []
        folderObject <-
            Schema.object
                "folder"
                [Schema.relation "viewer" [Schema.subject "user"] Schema.this]
        Schema.build [userObject, folderObject]

wideFolder :: ObjectRef
wideFolder =
    ObjectRef (ObjectType "folder") "wide"

wideMember :: ObjectRef
wideMember =
    ObjectRef (ObjectType "user") "member-1024"

outsider :: ObjectRef
outsider =
    ObjectRef (ObjectType "user") "outsider"

wideTuples :: [Tuple]
wideTuples =
    [ Tuple wideFolder (RelationName "viewer") (SubjectId (ObjectRef (ObjectType "user") ("member-" <> Text.pack (show index)))) Nothing
    | index <- [1 :: Int .. 2048]
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
