{-# LANGUAGE DataKinds #-}

module Main (main) where

import Data.Map.Strict qualified as Map
import Data.Text qualified as Text
import Effectful (Eff, runPureEff)
import Effectful.Error.Static (Error, runErrorNoCallStack)
import En.Cache (Cache, CacheConfig (..), insertCache, newCache)
import En.Check (BatchPair (..), check, checkMany)
import En.Conformance.Kikan (runConsistencyStoreInMemory, runTupleStoreInMemory)
import En.Decision (CheckDecision (..))
import En.Effect.ConsistencyStore (ConsistencyStore)
import En.Effect.TupleStore (TupleStore)
import En.Error (EnError)
import En.Expand (ExpandLimit (..), ExpandRequest (..), ExpandTree (..), expand)
import En.Lookup (LookupLimit (..), LookupPage (..), LookupRequest (..))
import En.Lookup qualified as Lookup
import En.Reachability (ReachabilityGraph, compileSchema)
import En.Revision (Consistency (..))
import En.Schema (ObjectType (..), RelationName (..), Schema)
import En.Schema.Builder qualified as Schema
import En.Tuple (CaveatContext (..), ObjectRef (..), Subject (..), Tuple (..))
import Test.Tasty.Bench (bench, bgroup, defaultMain, whnfAppIO)
import Prelude hiding (lookup)

-- | Every benchmark applies its engine call to an argument the fixture supplies,
-- rather than closing over one.
--
-- A @\\() -> action@ thunk is a constant expression, and GHC's full-laziness pass
-- floats it out of the lambda: the benchmark then measures a memoized result rather
-- than the work. It is not a hypothetical -- @lookup\/wide-fanout@ first reported
-- 2.29 ns, three orders of magnitude below the cheapest real bench in this file.
-- Applying the function to a value it actually consumes keeps the work inside the
-- timed region.
main :: IO ()
main = do
  graph <- either (fail . show) pure (compileSchema benchSchema)
  wideGraph <- either (fail . show) pure (compileSchema wideSchema)
  assertFixtures graph wideGraph
  defaultMain
    [ bgroup
        "check"
        [ bench "shallow-owner" $
            whnfAppIO (\object -> runEngine (check graph MinimizeLatency emptyContext (SubjectId user) (RelationName "view") object)) space,
          bench "nested-parent" $
            whnfAppIO (\object -> runEngine (check graph MinimizeLatency emptyContext (SubjectId user) (RelationName "view") object)) childSpace,
          bench "deep-nested" $
            whnfAppIO (\object -> runDeepEngine (check graph MinimizeLatency emptyContext (SubjectId user) (RelationName "view") object)) deepLeaf
        ],
      bgroup
        "checkMany"
        [ bench "overlapping" $
            whnfAppIO (\pairs -> runEngine (checkMany graph MinimizeLatency emptyContext pairs)) overlappingPairs,
          bench "wide-overlapping" $
            whnfAppIO (\pairs -> runWideEngine (checkMany wideGraph MinimizeLatency emptyContext pairs)) wideOverlappingPairs
        ],
      bgroup
        "lookup"
        [ bench "reachable-spaces" $
            whnfAppIO (\request -> runEngine (Lookup.lookup graph MinimizeLatency request)) viewSpacesRequest,
          bench "wide-fanout" $
            whnfAppIO (\request -> runFanoutEngine (Lookup.lookup wideGraph MinimizeLatency request)) fanoutRequest
        ],
      bgroup
        "expand"
        [ bench "deep-nested" $
            whnfAppIO (\request -> runDeepEngine (expand graph MinimizeLatency request)) deepExpandRequest
        ],
      -- Before the point-membership probe landed, neither of these ran at all:
      -- a relation wider than one 1000-row page failed the check with
      -- ResolutionLimitExceeded. The first numbers recorded here are therefore
      -- the baseline for docs/plans/44 to improve on, not a regression target.
      bgroup
        "check-wide"
        [ bench "direct-member" $
            whnfAppIO (\subject -> runWideEngine (check wideGraph MinimizeLatency emptyContext subject (RelationName "viewer") wideFolder)) (SubjectId wideMember),
          bench "non-member" $
            whnfAppIO (\subject -> runWideEngine (check wideGraph MinimizeLatency emptyContext subject (RelationName "viewer") wideFolder)) (SubjectId outsider)
        ],
      bgroup
        "cache"
        [ bench "evict-churn" $ whnfAppIO evictChurn evictChurnInserts
        ]
    ]

-- | Run every benchmarked call once and pin its answer.
--
-- A benchmark reports a time whatever the engine returns, so an @UnknownRelation@
-- from a mistyped fixture reads as a fast benchmark and a denial reads as an
-- expensive one. These assertions are the fixtures' meaning: @non-member@ is
-- expensive /because it denies after draining the relation/, and a future edit that
-- turns it into an early error would otherwise look like an optimization.
assertFixtures :: ReachabilityGraph -> ReachabilityGraph -> IO ()
assertFixtures graph wideGraph = do
  expectEq "check/shallow-owner" (Right Allowed) =<< runEngine (check graph MinimizeLatency emptyContext (SubjectId user) (RelationName "view") space)
  expectEq "check/nested-parent" (Right Allowed) =<< runEngine (check graph MinimizeLatency emptyContext (SubjectId user) (RelationName "view") childSpace)
  expectEq "check/deep-nested" (Right Allowed) =<< runDeepEngine (check graph MinimizeLatency emptyContext (SubjectId user) (RelationName "view") deepLeaf)
  expectEq "checkMany/overlapping" (Right [Right Allowed, Right Allowed, Right Allowed]) =<< runEngine (checkMany graph MinimizeLatency emptyContext overlappingPairs)
  expectEq "checkMany/wide-overlapping" (Right [Right Allowed, Right Allowed, Right Allowed]) =<< runWideEngine (checkMany wideGraph MinimizeLatency emptyContext wideOverlappingPairs)
  expectEq "check-wide/direct-member" (Right Allowed) =<< runWideEngine (check wideGraph MinimizeLatency emptyContext (SubjectId wideMember) (RelationName "viewer") wideFolder)
  expectEq "check-wide/non-member" (Right Denied) =<< runWideEngine (check wideGraph MinimizeLatency emptyContext (SubjectId outsider) (RelationName "viewer") wideFolder)
  expectEq "lookup/reachable-spaces" (Right 2) . fmap (length . (.objects)) =<< runEngine (Lookup.lookup graph MinimizeLatency viewSpacesRequest)
  expectEq "lookup/wide-fanout" (Right 50) . fmap (length . (.objects)) =<< runFanoutEngine (Lookup.lookup wideGraph MinimizeLatency fanoutRequest)
  expectEq "expand/deep-nested" (Right deepLeaf) . fmap (.root) =<< runDeepEngine (expand graph MinimizeLatency deepExpandRequest)

expectEq :: (Eq a, Show a) => String -> a -> a -> IO ()
expectEq label expected actual
  | expected == actual = pure ()
  | otherwise = fail (label <> ": expected " <> show expected <> ", got " <> show actual)

runEngine :: Eff '[ConsistencyStore, TupleStore, Error EnError] a -> IO (Either EnError a)
runEngine action =
  pure (runPureEff (runErrorNoCallStack (runTupleStoreInMemory benchTuples (runConsistencyStoreInMemory action))))

runWideEngine :: Eff '[ConsistencyStore, TupleStore, Error EnError] a -> IO (Either EnError a)
runWideEngine action =
  pure (runPureEff (runErrorNoCallStack (runTupleStoreInMemory wideTuples (runConsistencyStoreInMemory action))))

runFanoutEngine :: Eff '[ConsistencyStore, TupleStore, Error EnError] a -> IO (Either EnError a)
runFanoutEngine action =
  pure (runPureEff (runErrorNoCallStack (runTupleStoreInMemory fanoutTuples (runConsistencyStoreInMemory action))))

runDeepEngine :: Eff '[ConsistencyStore, TupleStore, Error EnError] a -> IO (Either EnError a)
runDeepEngine action =
  pure (runPureEff (runErrorNoCallStack (runTupleStoreInMemory deepTuples (runConsistencyStoreInMemory action))))

-- | Insert past a small capacity so most inserts evict. This is the eviction
-- victim search, isolated: the map stays small, and what varies is how the victim
-- is found.
evictChurn :: Int -> IO ()
evictChurn inserts = do
  cache <- newCache CacheConfig {enabled = True, maxEntries = evictChurnCapacity} :: IO (Cache Int Int)
  mapM_ (\key -> insertCache cache key key) [1 .. inserts]

evictChurnCapacity :: Int
evictChurnCapacity = 128

evictChurnInserts :: Int
evictChurnInserts = 2000

benchSchema :: Schema
benchSchema =
  either (error . ("invalid benchmark schema fixture: " <>) . show) id $ do
    userObject <- Schema.object "user" []
    spaceObject <-
      Schema.object
        "space"
        [ Schema.relation "owner" [Schema.subject "user"] Schema.this,
          Schema.relation "parent" [Schema.subject "space"] Schema.this,
          Schema.permission "view" (Schema.anyOf (Schema.computed "owner") [Schema.arrow "parent" "view"])
        ]
    Schema.build [userObject, spaceObject]

benchTuples :: [Tuple]
benchTuples =
  [ Tuple space (RelationName "owner") (SubjectId user) Nothing,
    Tuple childSpace (RelationName "parent") (SubjectId space) Nothing
  ]

-- | A @parent@ chain of 20 spaces with the owner at the root.
--
-- Twenty hops sit under the default @maxDepth = 25@, so the chain resolves rather
-- than failing, and every hop pushes a subproblem onto the @visited@ stack and
-- recurses through the @parent -> view@ arrow. This is the fixture that makes
-- recursion machinery -- the visited-set membership test, the per-level state
-- allocation -- visible at all: the two-tuple @nested-parent@ fixture has one hop.
deepChainLength :: Int
deepChainLength = 20

deepSpace :: Int -> ObjectRef
deepSpace index =
  ObjectRef (ObjectType "space") ("s" <> Text.pack (show index))

deepLeaf :: ObjectRef
deepLeaf =
  deepSpace deepChainLength

deepTuples :: [Tuple]
deepTuples =
  Tuple (deepSpace 1) (RelationName "owner") (SubjectId user) Nothing
    : [ Tuple (deepSpace (index + 1)) (RelationName "parent") (SubjectId (deepSpace index)) Nothing
      | index <- [1 .. deepChainLength - 1]
      ]

deepExpandRequest :: ExpandRequest
deepExpandRequest =
  ExpandRequest
    { object = deepLeaf,
      permission = RelationName "view",
      context = emptyContext,
      limit = ExpandLimit 50,
      cursor = Nothing
    }

-- | A folder relation far wider than one read page, attached to many nested groups.
--
-- @team#member@ is a /permission/ over @team#direct@ rather than a bare @this@, which
-- is what keeps EP-39's batched nested-group accelerator from settling these rows: a
-- stored membership tuple alone does not prove a relation that unions in no @this@.
-- So a check that the probe cannot answer recurses into every group, which is the
-- path where the evaluation folds accumulate.
--
-- @folder#reader@ unions four wide relations over overlapping object sets, so a lookup
-- over it merges four large already-merged branch results -- the per-union-node re-merge
-- finding B12 names. Four rather than two because a two-branch union performs exactly one
-- combining step, which cannot distinguish a merge that is cheap from one that re-sorts.
wideSchema :: Schema
wideSchema =
  either (error . ("invalid wide benchmark schema fixture: " <>) . show) id $ do
    userObject <- Schema.object "user" []
    teamObject <-
      Schema.object
        "team"
        [ Schema.relation "direct" [Schema.subject "user"] Schema.this,
          Schema.permission "member" (Schema.computed "direct")
        ]
    folderObject <-
      Schema.object
        "folder"
        [ Schema.relation "viewer" [Schema.subject "user", Schema.userset "team" "member"] Schema.this,
          Schema.relation "editor" [Schema.subject "user"] Schema.this,
          Schema.relation "commenter" [Schema.subject "user"] Schema.this,
          Schema.relation "auditor" [Schema.subject "user"] Schema.this,
          Schema.permission
            "reader"
            ( Schema.anyOf
                (Schema.computed "viewer")
                [Schema.computed "editor", Schema.computed "commenter", Schema.computed "auditor"]
            )
        ]
    Schema.build [userObject, teamObject, folderObject]

wideViewerCount :: Int
wideViewerCount = 5000

teamCount :: Int
teamCount = 64

wideFolder :: ObjectRef
wideFolder =
  ObjectRef (ObjectType "folder") "wide"

wideFolders :: [ObjectRef]
wideFolders =
  [wideFolder, ObjectRef (ObjectType "folder") "wide2", ObjectRef (ObjectType "folder") "wide3"]

benchTeam :: Int -> ObjectRef
benchTeam index =
  ObjectRef (ObjectType "team") ("t" <> Text.pack (show index))

wideUser :: Int -> ObjectRef
wideUser index =
  ObjectRef (ObjectType "user") ("member-" <> Text.pack (show index))

wideMember :: ObjectRef
wideMember =
  wideUser (wideViewerCount `div` 2)

teamMember :: ObjectRef
teamMember =
  ObjectRef (ObjectType "user") "team-member"

outsider :: ObjectRef
outsider =
  ObjectRef (ObjectType "user") "outsider"

wideTuples :: [Tuple]
wideTuples =
  [ Tuple wideFolder (RelationName "viewer") (SubjectId (wideUser index)) Nothing
  | index <- [1 .. wideViewerCount]
  ]
    <> [ Tuple folder (RelationName "viewer") (SubjectSet (benchTeam index) (RelationName "member")) Nothing
       | folder <- wideFolders,
         index <- [1 .. teamCount]
       ]
    <> [Tuple (benchTeam teamCount) (RelationName "direct") (SubjectId teamMember) Nothing]

-- | Three folders sharing one set of groups, asked about one subject.
--
-- The first pair recurses into every group; the second and third find those
-- subproblems in the batch's memo. What the bench measures is whether that sharing
-- survives the fold rewrites.
wideOverlappingPairs :: [BatchPair]
wideOverlappingPairs =
  [BatchPair (SubjectId teamMember) (RelationName "viewer") folder | folder <- wideFolders]

fanoutViewerCount :: Int
fanoutViewerCount = 1200

fanoutUser :: ObjectRef
fanoutUser =
  ObjectRef (ObjectType "user") "fanout"

fanFolder :: Int -> ObjectRef
fanFolder index =
  ObjectRef (ObjectType "folder") ("fan-" <> Text.pack (show index))

-- | Four overlapping grants over the same 1,200 folders: 3,000 rows resolving to
-- 1,200 distinct objects, so every union branch carries objects the others also carry
-- and the merge has real work to do.
fanoutTuples :: [Tuple]
fanoutTuples =
  concat
    [ [Tuple (fanFolder index) (RelationName "viewer") (SubjectId fanoutUser) Nothing | index <- [1 .. fanoutViewerCount]],
      [Tuple (fanFolder index) (RelationName "editor") (SubjectId fanoutUser) Nothing | index <- [1 .. 600]],
      [Tuple (fanFolder index) (RelationName "commenter") (SubjectId fanoutUser) Nothing | index <- [301 .. 1200]],
      [Tuple (fanFolder index) (RelationName "auditor") (SubjectId fanoutUser) Nothing | index <- [1 .. 300]]
    ]

-- | A subject reaching 1,200 folders through a union of four wide branches.
--
-- The page is 50 objects, so nothing here is about page size: the traversal finds all
-- 3,000 rows, merges each branch, and then merges the four branches together.
fanoutRequest :: LookupRequest
fanoutRequest =
  LookupRequest
    { subject = SubjectId fanoutUser,
      permission = RelationName "reader",
      objectType = ObjectType "folder",
      context = emptyContext,
      limit = LookupLimit 50,
      cursor = Nothing
    }

viewSpacesRequest :: LookupRequest
viewSpacesRequest =
  LookupRequest
    { subject = SubjectId user,
      permission = RelationName "view",
      objectType = space.objectType,
      context = emptyContext,
      limit = LookupLimit 50,
      cursor = Nothing
    }

overlappingPairs :: [BatchPair]
overlappingPairs =
  [ BatchPair (SubjectId user) (RelationName "view") space,
    BatchPair (SubjectId user) (RelationName "owner") space,
    BatchPair (SubjectId user) (RelationName "view") childSpace
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
