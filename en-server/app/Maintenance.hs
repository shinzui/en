{- | Scheduled background maintenance for @en-server@.

en never physically deletes on the write path: deleting a relationship tuple sets
@deleted_xid@ (a soft delete, so historical reads at older snapshots still see the row)
and every write inserts one bookkeeping row into @en_transaction@. Both accumulate
forever unless something removes them. Nothing did.

This module is that something. On an interval it advances the garbage-collection
horizon -- the oldest transaction id still protected by @EN_GC_WINDOW@ -- and then
deletes, in bounded batches, every soft-deleted tuple and every transaction row behind
it. The horizon is a durable high-water mark (@en_gc_horizon@): this pass advances it
and reaps at the advanced value, while token validation reads that same mark, so the
reaper, the pruner, and token validation can never disagree about what is safe to
remove -- not even across time or across replicas, which a horizon recomputed from
scratch each pass could not guarantee (@docs/plans/60@ Milestone 4).

Pruning @en_transaction@ is not merely housekeeping. The horizon query is a @min(xid)@
over the retention window, and PostgreSQL answers it by walking the @xid@ primary key
until it finds the first row inside the window. Rows behind the horizon are exactly the
rows it must skip, so an unpruned table makes every read pay for every write ever made.
Draining them keeps that scan at its first row.
-}
module Maintenance (
    MaintenanceConfig (..),
    describeMaintenance,
    runMaintenanceLoop,
) where

import Control.Concurrent (threadDelay)
import Control.Exception (SomeAsyncException, SomeException, fromException, throwIO, try)
import Control.Monad (forever)
import Data.Int (Int64)
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Text.IO qualified as Text
import Effectful (Eff)

import En.Effect.TupleStore qualified as TupleStore
import En.Error (EnError)
import En.Postgres.Database (runSession)
import En.Postgres.TupleStore (pruneTransactionsBatchSession, reapDeletedTuplesBatchSession)
import En.Servant.Seam (AppEffects)
import Hasql.Errors qualified as Hasql
import Hasql.Session (Session)

data MaintenanceConfig = MaintenanceConfig
    { intervalSeconds :: !Int
    -- ^ Seconds between passes. Zero disables the loop entirely.
    , batchSize :: !Int
    -- ^ Rows deleted per statement. Each batch is its own transaction.
    }

{- | The natural transformation @Main@ builds; the loop borrows a pooled connection
per session through it, exactly as a request handler does.
-}
type RunApp = forall a. Eff AppEffects a -> IO (Either EnError a)

describeMaintenance :: MaintenanceConfig -> Text
describeMaintenance config
    | config.intervalSeconds <= 0 = "disabled"
    | otherwise =
        "enabled, intervalSeconds="
            <> Text.pack (show config.intervalSeconds)
            <> ", batchSize="
            <> Text.pack (show config.batchSize)

{- | Sleep, run a pass, repeat. Never returns.

Intended to run under @withAsync@ so the server's graceful shutdown cancels it. Both
'threadDelay' and the database sessions are interruptible, and every batch is a
committed transaction, so cancellation at any point loses only the batch in flight.

A pass that fails -- most plausibly because PostgreSQL is restarting -- is logged and
the schedule continues. Asynchronous exceptions are re-thrown rather than logged, or
cancellation would be swallowed and the thread would outlive the server.
-}
runMaintenanceLoop :: MaintenanceConfig -> RunApp -> IO ()
runMaintenanceLoop config runApp
    | config.intervalSeconds <= 0 = pure ()
    | otherwise = forever do
        threadDelay (config.intervalSeconds * 1_000_000)
        outcome <- try @SomeException (runPass config runApp)
        case outcome of
            Right () -> pure ()
            Left err
                | isAsync err -> throwIO err
                | otherwise -> logLine ("pass failed: " <> Text.pack (show err))
  where
    isAsync err =
        case fromException err :: Maybe SomeAsyncException of
            Just _ -> True
            Nothing -> False

{- | One pass: advance the horizon, drain the reap backlog, drain the prune backlog,
and report. A database error at any step abandons the pass; the next one starts over,
and whatever the failed pass committed stays committed.

The horizon is fixed by 'TupleStore.advanceGcHorizon', which advances the durable
high-water mark ('en_gc_horizon') and returns it before any row is destroyed. Token
validation reads that same mark ('TupleStore.oldestRetainedXid'), so once a pass has
published its horizon, no later validation — on this replica or another — can fall
below it and bless a snapshot needing a row this pass reaps. Publishing before
reaping is what makes reaping and validation agree across time; see @docs/plans/60@
Milestone 4.
-}
runPass :: MaintenanceConfig -> RunApp -> IO ()
runPass config runApp =
    runApp TupleStore.advanceGcHorizon >>= \case
        Left err -> logLine ("could not advance the garbage-collection horizon: " <> renderEnError err)
        Right horizon ->
            drain (reapDeletedTuplesBatchSession horizon) >>= \case
                Left err -> logLine ("reap failed at horizon " <> render horizon <> ": " <> err)
                Right (reaped, reapBatches) ->
                    drain (pruneTransactionsBatchSession horizon) >>= \case
                        Left err -> logLine ("prune failed at horizon " <> render horizon <> ": " <> err)
                        Right (pruned, pruneBatches) ->
                            logLine $
                                "horizon="
                                    <> render horizon
                                    <> " reaped="
                                    <> render reaped
                                    <> " pruned="
                                    <> render pruned
                                    <> " batches="
                                    <> render (reapBatches + pruneBatches)
  where
    render :: (Show a) => a -> Text
    render = Text.pack . show

    -- Repeat the batch until it comes back short, which means the backlog is drained.
    -- A full batch is never evidence of completion: the next one may still find rows.
    drain :: (Int -> Session Int64) -> IO (Either Text (Int64, Int))
    drain session = go 0 0
      where
        go !removedSoFar !batches =
            runBatch runApp (session config.batchSize) >>= \case
                Left err -> pure (Left err)
                Right removed
                    | removed < fromIntegral config.batchSize ->
                        pure (Right (removedSoFar + removed, batches + 1))
                    | otherwise ->
                        go (removedSoFar + removed) (batches + 1)

{- | Flatten the two error layers a session acquires on its way out: @runApp@ reports
effect-level failure, @runSession@ reports statement- and connection-level failure.
-}
runBatch :: RunApp -> Session Int64 -> IO (Either Text Int64)
runBatch runApp session =
    runApp (runSession session) >>= \case
        Left err -> pure (Left (renderEnError err))
        Right (Left sessionError) -> pure (Left (Hasql.toDetailedText sessionError))
        Right (Right removed) -> pure (Right removed)

renderEnError :: EnError -> Text
renderEnError = Text.pack . show

logLine :: Text -> IO ()
logLine message =
    Text.putStrLn ("maintenance: " <> message)
