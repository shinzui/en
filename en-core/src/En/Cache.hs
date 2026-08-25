{-# LANGUAGE NoFieldSelectors #-}

-- | Small bounded in-process caches and cache keys shared by en engines.
module En.Cache
  ( CacheConfig (..),
    CacheStats (..),
    Cache,
    TupleReadKey (..),
    DecisionKey (..),
    SubproblemKey (..),
    newCache,
    lookupCache,
    insertCache,
    cacheStats,
  )
where

import Data.IORef (IORef, atomicModifyIORef', newIORef, readIORef)
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import En.Effect.TupleStore (StoreCursor, UsersetQuery (..))
import En.Revision (DatastoreId, Revision (..), SchemaHash)
import En.Schema (ObjectType, RelationName)
import En.Tuple (CaveatContext, ObjectRef, Subject)

data CacheConfig = CacheConfig
  { enabled :: !Bool,
    maxEntries :: !Int
  }
  deriving stock (Eq, Show)

data CacheStats = CacheStats
  { hits :: !Int,
    misses :: !Int,
    inserts :: !Int,
    evictions :: !Int
  }
  deriving stock (Eq, Show)

data Cache key value = Cache
  { config :: !CacheConfig,
    state :: !(IORef (CacheState key value))
  }

-- | 'bySequence' is the eviction index: insertion ordinal to key, so the oldest
-- entry is 'Map.lookupMin' rather than a fold over every entry. It is maintained in
-- lockstep with 'entries' -- re-inserting an existing key must first drop that key's
-- previous ordinal, or the index accumulates ordinals pointing at keys it no longer
-- owns and eviction starts choosing victims that are not the oldest.
data CacheState key value = CacheState
  { entries :: !(Map key (CacheEntry value)),
    bySequence :: !(Map Int key),
    nextSequence :: !Int,
    stats :: !CacheStats
  }

data CacheEntry value = CacheEntry
  { sequenceNumber :: !Int,
    value :: value
  }

-- | Identifies one tuple-store read. Every variant pins the resolved revision the
-- engine asked for, which is what makes an entry safe to reuse: it can never serve
-- rows from a different snapshot.
--
-- 'ProbeReadKey' is the point-membership probe -- "which of these subjects are named
-- directly by @object#relation@?" -- and its subject list is part of the key,
-- because a probe for a different set of subjects is a different question.
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
      (ObjectRelationReadKey {}, StartingWithUserReadKey {}) -> LT
      (StartingWithUserReadKey {}, ObjectRelationReadKey {}) -> GT
      (ProbeReadKey {}, _) -> GT
      (_, ProbeReadKey {}) -> LT

data DecisionKey = DecisionKey
  { datastoreId :: !DatastoreId,
    schemaHash :: !SchemaHash,
    revision :: !Revision,
    subject :: !Subject,
    permission :: !RelationName,
    object :: !ObjectRef,
    context :: !CaveatContext
  }
  deriving stock (Eq, Show)

instance Ord DecisionKey where
  compare left right =
    compare
      (left.datastoreId, left.schemaHash, revisionEncoding left.revision, left.subject, left.permission, left.object, left.context)
      (right.datastoreId, right.schemaHash, revisionEncoding right.revision, right.subject, right.permission, right.object, right.context)

-- | Identifies one check subproblem: "is @subject@ a member of @object#relation@,
-- at this revision, under this schema, in this datastore?"
--
-- The request's caveat context is deliberately /not/ part of the key. The value
-- stored under it is an @En.Decision.ResidualDecision@ -- the answer with its
-- caveats left symbolic — which is correct for every request that asks this
-- question, whatever context each one carries. Each request folds its own context
-- in on the way out.
--
-- Putting the context in the key is what made this cache useless: the canonical
-- caveat is a time-bounded grant, virtually every request carries a fresh
-- @current_time@, so every key was unique and the cross-request hit rate was
-- approximately zero. Excluding it cannot serve a stale answer, because no
-- context-dependent value is stored.
data SubproblemKey = SubproblemKey
  { datastoreId :: !DatastoreId,
    schemaHash :: !SchemaHash,
    revision :: !Revision,
    subject :: !Subject,
    relation :: !RelationName,
    object :: !ObjectRef
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
  pure Cache {config, state}

-- | A disabled cache performs no write at all, not even to count the miss.
--
-- Counting a miss on a disabled cache means an @atomicModifyIORef'@ -- a
-- compare-and-swap on one shared cell -- on every read of a feature nobody turned
-- on. Under concurrency that is a contention point serving no purpose: a disabled
-- cache's hit rate has no operational meaning. The stats of a disabled cache are
-- therefore all zero, which is the honest report.
lookupCache :: (Ord key) => Cache key value -> key -> IO (Maybe value)
lookupCache cache key
  | disabled cache = pure Nothing
  | otherwise =
      atomicModifyIORef' cache.state \state ->
        case Map.lookup key state.entries of
          Nothing ->
            let updated = state {stats = state.stats {misses = state.stats.misses + 1}}
             in (updated, Nothing)
          Just entry ->
            let updated = state {stats = state.stats {hits = state.stats.hits + 1}}
             in (updated, Just entry.value)

insertCache :: (Ord key) => Cache key value -> key -> value -> IO ()
insertCache cache key value
  | disabled cache = pure ()
  | otherwise =
      atomicModifyIORef' cache.state \state ->
        let entry = CacheEntry {sequenceNumber = state.nextSequence, value}
            inserted = Map.insert key entry state.entries
            -- Re-inserting a key retires its old ordinal; leaving it would make
            -- the index name a key whose entry has since been replaced.
            indexed =
              Map.insert state.nextSequence key $
                case Map.lookup key state.entries of
                  Nothing -> state.bySequence
                  Just existing -> Map.delete existing.sequenceNumber state.bySequence
            (boundedEntries, boundedIndex, evictionCount) =
              evictOldest cache.config.maxEntries inserted indexed
            updated =
              state
                { entries = boundedEntries,
                  bySequence = boundedIndex,
                  nextSequence = state.nextSequence + 1,
                  stats =
                    state.stats
                      { inserts = state.stats.inserts + 1,
                        evictions = state.stats.evictions + evictionCount
                      }
                }
         in (updated, ())

disabled :: Cache key value -> Bool
disabled cache =
  not cache.config.enabled || cache.config.maxEntries <= 0

cacheStats :: Cache key value -> IO CacheStats
cacheStats cache =
  (.stats) <$> readIORef cache.state

emptyCacheState :: CacheState key value
emptyCacheState =
  CacheState
    { entries = Map.empty,
      bySequence = Map.empty,
      nextSequence = 0,
      stats = CacheStats {hits = 0, misses = 0, inserts = 0, evictions = 0}
    }

-- | Evict in insertion order until the cache fits, via the sequence index.
--
-- FIFO, not LRU: the victim is the least-recently /inserted/ entry, and a hit does
-- not move it. True LRU would need a write on every cache hit, reintroducing on the
-- read path exactly the contention 'lookupCache' just removed from the disabled
-- path. Finding the victim was a @Map.foldrWithKey@ over every entry; it is now
-- 'Map.lookupMin' on the index.
evictOldest ::
  (Ord key) =>
  Int ->
  Map key (CacheEntry value) ->
  Map Int key ->
  (Map key (CacheEntry value), Map Int key, Int)
evictOldest maxEntries entries index
  | Map.size entries <= maxEntries = (entries, index, 0)
  | otherwise =
      case Map.lookupMin index of
        Nothing -> (entries, index, 0)
        Just (sequenceNumber, key) ->
          let (bounded, boundedIndex, count) =
                evictOldest maxEntries (Map.delete key entries) (Map.delete sequenceNumber index)
           in (bounded, boundedIndex, count + 1)

usersetQueryKey :: UsersetQuery -> (ObjectType, RelationName, [Subject], Int, Maybe StoreCursor)
usersetQueryKey query =
  (query.queryType, query.queryRelation, query.querySubjects, query.queryLimit, query.queryCursor)
