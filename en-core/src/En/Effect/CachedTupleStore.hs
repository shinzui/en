-- | TupleStore read cache interposer.
module En.Effect.CachedTupleStore
  ( cachedTupleStore,
  )
where

import Effectful (Eff, IOE, liftIO, (:>))
import Effectful.Dispatch.Dynamic (interpose, passthrough, send)
import En.Cache (Cache, TupleReadKey (..), insertCache, lookupCache)
import En.Effect.TupleStore (PageState (..), TuplePage (..), TupleStore (..))

-- | Cache tuple-store read pages by resolved revision and read parameters.
--
-- The interposer is intentionally narrow: it caches only the three read shapes the
-- engine issues on the check and lookup paths -- 'ReadObjectRelation',
-- 'ReadStartingWithUser', and 'ProbeTuples'. Writes, revision reads, maintenance
-- operations, and the bulk drain 'ReadAllTuples' are forwarded to the upstream
-- 'TupleStore' handler unchanged. Entries are safe to reuse because every key
-- includes the resolved revision supplied by the engine, so an entry can never
-- serve rows from a different snapshot.
--
-- 'ReadAllTuples' is deliberately uncached rather than merely unhandled: an export
-- reads each of its pages exactly once, so caching them buys nothing and would
-- evict the hot check-path entries this cache exists to hold.
--
-- A probe returns a bare row list rather than a page, because it is unpaginated by
-- construction: it asks for the rows naming specific subjects, and there are as many
-- as there are. Storing it as an 'Exhausted' 'TuplePage' is therefore truthful, and
-- it lets probes share the one cache and its bound rather than introducing a second.
cachedTupleStore ::
  (TupleStore :> es, IOE :> es) =>
  Cache TupleReadKey TuplePage ->
  Eff es a ->
  Eff es a
cachedTupleStore cache =
  interpose \env -> \case
    ReadObjectRelation revision object relation limit cursor ->
      cachedRead
        cache
        (ObjectRelationReadKey revision object relation limit cursor)
        (send (ReadObjectRelation revision object relation limit cursor))
    ReadStartingWithUser revision query ->
      cachedRead
        cache
        (StartingWithUserReadKey revision query)
        (send (ReadStartingWithUser revision query))
    ProbeTuples revision object relation subjects ->
      (.rows)
        <$> cachedRead
          cache
          (ProbeReadKey revision object relation subjects)
          (probePage revision object relation subjects)
    operation ->
      passthrough env operation
  where
    probePage revision object relation subjects = do
      rows <- send (ProbeTuples revision object relation subjects)
      pure TuplePage {rows, state = Exhausted}

cachedRead ::
  (IOE :> es) =>
  Cache TupleReadKey TuplePage ->
  TupleReadKey ->
  Eff es TuplePage ->
  Eff es TuplePage
cachedRead cache key readFresh = do
  cached <- liftIO (lookupCache cache key)
  case cached of
    Just page -> pure page
    Nothing -> do
      page <- readFresh
      liftIO (insertCache cache key page)
      pure page
