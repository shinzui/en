{-# LANGUAGE NoFieldSelectors #-}

-- | Small bounded in-process caches and cache keys shared by en engines.
module En.Cache (
    CacheConfig (..),
    CacheStats (..),
    Cache,
    TupleReadKey (..),
    DecisionKey (..),
    SubproblemKey (..),
    newCache,
    lookupCache,
    insertCache,
    cacheStats,
) where

import Data.IORef (IORef, atomicModifyIORef', newIORef, readIORef)
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map

import En.Effect.TupleStore (StoreCursor, UsersetQuery (..))
import En.Revision (DatastoreId, Revision (..), SchemaHash)
import En.Schema (ObjectType, RelationName)
import En.Tuple (CaveatContext, ObjectRef, Subject)

data CacheConfig = CacheConfig
    { enabled :: !Bool
    , maxEntries :: !Int
    }
    deriving stock (Eq, Show)

data CacheStats = CacheStats
    { hits :: !Int
    , misses :: !Int
    , inserts :: !Int
    , evictions :: !Int
    }
    deriving stock (Eq, Show)

data Cache key value = Cache
    { config :: !CacheConfig
    , state :: !(IORef (CacheState key value))
    }

data CacheState key value = CacheState
    { entries :: !(Map key (CacheEntry value))
    , nextSequence :: !Int
    , stats :: !CacheStats
    }

data CacheEntry value = CacheEntry
    { sequenceNumber :: !Int
    , value :: value
    }

{- | Identifies one tuple-store read. Every variant pins the resolved revision the
engine asked for, which is what makes an entry safe to reuse: it can never serve
rows from a different snapshot.

'ProbeReadKey' is the point-membership probe -- "which of these subjects are named
directly by @object#relation@?" -- and its subject list is part of the key,
because a probe for a different set of subjects is a different question.
-}
data TupleReadKey
    = ObjectRelationReadKey !Revision !ObjectRef !RelationName !Int !(Maybe StoreCursor)
    | StartingWithUserReadKey !Revision !UsersetQuery
    | ProbeReadKey !Revision !ObjectRef !RelationName ![Subject]
    deriving stock (Eq, Show)

instance Ord TupleReadKey where
    compare left right =
        case (left, right) of
            (ObjectRelationReadKey leftRevision leftObject leftRelation leftLimit leftCursor, ObjectRelationReadKey rightRevision rightObject rightRelation rightLimit rightCursor) ->
                compare
                    (revisionEncoding leftRevision, leftObject, leftRelation, leftLimit, leftCursor)
                    (revisionEncoding rightRevision, rightObject, rightRelation, rightLimit, rightCursor)
            (StartingWithUserReadKey leftRevision leftQuery, StartingWithUserReadKey rightRevision rightQuery) ->
                compare
                    (revisionEncoding leftRevision, usersetQueryKey leftQuery)
                    (revisionEncoding rightRevision, usersetQueryKey rightQuery)
            (ProbeReadKey leftRevision leftObject leftRelation leftSubjects, ProbeReadKey rightRevision rightObject rightRelation rightSubjects) ->
                compare
                    (revisionEncoding leftRevision, leftObject, leftRelation, leftSubjects)
                    (revisionEncoding rightRevision, rightObject, rightRelation, rightSubjects)
            (ObjectRelationReadKey{}, StartingWithUserReadKey{}) -> LT
            (StartingWithUserReadKey{}, ObjectRelationReadKey{}) -> GT
            (ProbeReadKey{}, _) -> GT
            (_, ProbeReadKey{}) -> LT

data DecisionKey = DecisionKey
    { datastoreId :: !DatastoreId
    , schemaHash :: !SchemaHash
    , revision :: !Revision
    , subject :: !Subject
    , permission :: !RelationName
    , object :: !ObjectRef
    , context :: !CaveatContext
    }
    deriving stock (Eq, Show)

instance Ord DecisionKey where
    compare left right =
        compare
            (left.datastoreId, left.schemaHash, revisionEncoding left.revision, left.subject, left.permission, left.object, left.context)
            (right.datastoreId, right.schemaHash, revisionEncoding right.revision, right.subject, right.permission, right.object, right.context)

{- | Identifies one check subproblem: "is @subject@ a member of @object#relation@,
at this revision, under this schema, in this datastore?"

The request's caveat context is deliberately /not/ part of the key. The value
stored under it is an @En.Decision.ResidualDecision@ -- the answer with its
caveats left symbolic — which is correct for every request that asks this
question, whatever context each one carries. Each request folds its own context
in on the way out.

Putting the context in the key is what made this cache useless: the canonical
caveat is a time-bounded grant, virtually every request carries a fresh
@current_time@, so every key was unique and the cross-request hit rate was
approximately zero. Excluding it cannot serve a stale answer, because no
context-dependent value is stored.
-}
data SubproblemKey = SubproblemKey
    { datastoreId :: !DatastoreId
    , schemaHash :: !SchemaHash
    , revision :: !Revision
    , subject :: !Subject
    , relation :: !RelationName
    , object :: !ObjectRef
    }
    deriving stock (Eq, Show)

instance Ord SubproblemKey where
    compare left right =
        compare
            (left.datastoreId, left.schemaHash, revisionEncoding left.revision, left.subject, left.relation, left.object)
            (right.datastoreId, right.schemaHash, revisionEncoding right.revision, right.subject, right.relation, right.object)

newCache :: CacheConfig -> IO (Cache key value)
newCache config = do
    state <- newIORef emptyCacheState
    pure Cache{config, state}

lookupCache :: (Ord key) => Cache key value -> key -> IO (Maybe value)
lookupCache cache key
    | not cache.config.enabled || cache.config.maxEntries <= 0 =
        atomicModifyIORef' cache.state \state ->
            let updated = state{stats = state.stats{misses = state.stats.misses + 1}}
             in (updated, Nothing)
    | otherwise =
        atomicModifyIORef' cache.state \state ->
            case Map.lookup key state.entries of
                Nothing ->
                    let updated = state{stats = state.stats{misses = state.stats.misses + 1}}
                     in (updated, Nothing)
                Just entry ->
                    let updated = state{stats = state.stats{hits = state.stats.hits + 1}}
                     in (updated, Just entry.value)

insertCache :: (Ord key) => Cache key value -> key -> value -> IO ()
insertCache cache key value
    | not cache.config.enabled || cache.config.maxEntries <= 0 = pure ()
    | otherwise =
        atomicModifyIORef' cache.state \state ->
            let entry = CacheEntry{sequenceNumber = state.nextSequence, value}
                inserted = Map.insert key entry state.entries
                (boundedEntries, evictionCount) = evictOldest cache.config.maxEntries inserted
                updated =
                    state
                        { entries = boundedEntries
                        , nextSequence = state.nextSequence + 1
                        , stats =
                            state.stats
                                { inserts = state.stats.inserts + 1
                                , evictions = state.stats.evictions + evictionCount
                                }
                        }
             in (updated, ())

cacheStats :: Cache key value -> IO CacheStats
cacheStats cache =
    (.stats) <$> readIORef cache.state

emptyCacheState :: CacheState key value
emptyCacheState =
    CacheState
        { entries = Map.empty
        , nextSequence = 0
        , stats = CacheStats{hits = 0, misses = 0, inserts = 0, evictions = 0}
        }

evictOldest :: (Ord key) => Int -> Map key (CacheEntry value) -> (Map key (CacheEntry value), Int)
evictOldest maxEntries entries
    | Map.size entries <= maxEntries = (entries, 0)
    | otherwise =
        case oldestKey entries of
            Nothing -> (entries, 0)
            Just key ->
                let (bounded, count) = evictOldest maxEntries (Map.delete key entries)
                 in (bounded, count + 1)

oldestKey :: Map key (CacheEntry value) -> Maybe key
oldestKey =
    fmap fst . Map.foldrWithKey choose Nothing
  where
    choose key entry Nothing =
        Just (key, entry.sequenceNumber)
    choose key entry (Just oldest@(_, oldestSequence))
        | entry.sequenceNumber < oldestSequence = Just (key, entry.sequenceNumber)
        | otherwise = Just oldest

usersetQueryKey :: UsersetQuery -> (ObjectType, RelationName, [Subject], Int, Maybe StoreCursor)
usersetQueryKey query =
    (query.queryType, query.queryRelation, query.querySubjects, query.queryLimit, query.queryCursor)
