-- | TupleStore read cache interposer.
module En.Effect.CachedTupleStore (
    cachedTupleStore,
) where

import Effectful (Eff, IOE, liftIO, (:>))
import Effectful.Dispatch.Dynamic (interpose, passthrough, send)

import En.Cache (Cache, TupleReadKey (..), insertCache, lookupCache)
import En.Effect.TupleStore (TuplePage, TupleStore (..))

{- | Cache tuple-store read pages by resolved revision and read parameters.

The interposer is intentionally narrow: it caches only 'ReadObjectRelation' and
'ReadStartingWithUser'. Writes, revision reads, and maintenance operations are
forwarded to the upstream 'TupleStore' handler unchanged. Entries are safe to
reuse because every key includes the resolved revision supplied by the engine.
-}
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
        -- 'ProbeTuples' falls through here on purpose, not by oversight: whether a
        -- probe result is cached as a single-tuple entry or reused from a cached
        -- page is decided by docs/plans/41-cache-context-free-check-subproblems.md.
        operation ->
            passthrough env operation

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
