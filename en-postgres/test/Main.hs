{-# LANGUAGE DuplicateRecordFields #-}

module Main (main) where

import Data.Either (isLeft)
import Data.IORef (IORef, modifyIORef', newIORef, readIORef, writeIORef)
import Data.Text qualified as Text
import Data.Time (UTCTime, addUTCTime, defaultTimeLocale, parseTimeOrError)
import En.Effect.ConsistencyStore (ResolvedConsistency (..), TokenMetadata (..))
import En.Effect.TupleStore (StoreCursor (..))
import En.Error (EnError (..))
import En.Postgres.Revision
  ( ConsistencyConfig (..),
    OptimizedRevisionConfig (..),
    PgSnapshot (..),
    ResolveEnv (..),
    TokenPayload (..),
    comparePgSnapshot,
    decodeToken,
    encodeToken,
    newOptimizedRevisionReader,
    parsePgSnapshot,
    renderPgSnapshot,
    renderTokenDecodeError,
    resolveConsistencyRequest,
    retainedHistoryVisible,
    revisionFromPgSnapshot,
    transactionVisible,
    validateTokenMetadata,
  )
import En.Postgres.Watch
  ( WatchCursorState (..),
    decodeWatchCursor,
    encodeWatchCursor,
    validateWatchCursor,
  )
import En.Revision
  ( Consistency (..),
    ConsistencyToken (..),
    DatastoreId (..),
    Revision (..),
    RevisionOrder (..),
    SchemaHash (..),
  )

main :: IO ()
main = do
  testOptimizedRevisionReader
  testWatchCursorCodec
  assertEqual
    "pg_snapshot parses and renders canonically"
    (Right PgSnapshot {xmin = 10, xmax = 20, xip = [12, 15]})
    (parsePgSnapshot "10:20:15,12,12")
  assertEqual
    "pg_snapshot renders sorted xip"
    "10:20:12,15"
    (renderPgSnapshot PgSnapshot {xmin = 10, xmax = 20, xip = [15, 12]})
  assertEqual
    "old transaction is visible"
    True
    (transactionVisible 9 PgSnapshot {xmin = 10, xmax = 20, xip = [12]})
  assertEqual
    "in-flight transaction is not visible"
    False
    (transactionVisible 12 PgSnapshot {xmin = 10, xmax = 20, xip = [12]})
  assertEqual
    "future transaction is not visible"
    False
    (transactionVisible 20 PgSnapshot {xmin = 10, xmax = 20, xip = []})
  assertEqual
    "later snapshot compares after earlier snapshot"
    RAfter
    ( comparePgSnapshot
        PgSnapshot {xmin = 10, xmax = 30, xip = []}
        PgSnapshot {xmin = 10, xmax = 20, xip = []}
    )
  assertEqual
    "incomparable snapshots compare concurrent"
    RConcurrent
    ( comparePgSnapshot
        PgSnapshot {xmin = 10, xmax = 20, xip = [11]}
        PgSnapshot {xmin = 10, xmax = 20, xip = [12]}
    )
  assertEqual
    "xmax-gap snapshot compares before later snapshot"
    RBefore
    ( comparePgSnapshot
        PgSnapshot {xmin = 10, xmax = 15, xip = []}
        PgSnapshot {xmin = 20, xmax = 25, xip = []}
    )
  let payload =
        TokenPayload
          { datastoreId = DatastoreId "primary",
            schemaHash = SchemaHash "schema:hash",
            revision = revisionFromPgSnapshot PgSnapshot {xmin = 10, xmax = 20, xip = [12]},
            expiresAt = Nothing
          }
  assertEqual "token codec round-trips payload" (Right payload) (decodeToken (encodeToken payload))
  assertEqual "token decoder rejects bad snapshots" True (isLeft (decodeToken (ConsistencyToken "en1.primary.schema.bad")))
  assertEqual
    "exact snapshot resolves to token revision"
    (Right ResolvedConsistency {consistency = AtExactSnapshot (encodeToken payload), revision = payload.revision})
    =<< resolve optimizedRevision (AtExactSnapshot (encodeToken payload))
  assertEqual
    "fully consistent resolves to head revision"
    (Right ResolvedConsistency {consistency = FullyConsistent, revision = headRevision})
    =<< resolve optimizedRevision FullyConsistent
  assertEqual
    "at least as fresh uses optimized revision when it is after the token"
    (Right ResolvedConsistency {consistency = AtLeastAsFresh (encodeToken payload), revision = optimizedRevision})
    =<< resolve optimizedRevision (AtLeastAsFresh (encodeToken payload))
  let concurrentPayload =
        TokenPayload
          { datastoreId = payload.datastoreId,
            schemaHash = payload.schemaHash,
            revision = Revision "10:20:11",
            expiresAt = payload.expiresAt
          }
      concurrentOptimized = Revision "10:20:12"
  assertEqual
    "at least as fresh honors token revision when optimized is concurrent"
    (Right ResolvedConsistency {consistency = AtLeastAsFresh (encodeToken concurrentPayload), revision = concurrentPayload.revision})
    =<< resolve concurrentOptimized (AtLeastAsFresh (encodeToken concurrentPayload))

  -- The mode-to-requirement mapping (docs/plans/49, finding C3). Each getter is one
  -- database round trip in the real interpreter, except 'getNow', which is a clock
  -- read. What matters is that no mode forces a getter its answer does not depend on.
  assertEqual
    "minimize latency reads only the optimized revision"
    ["getOptimized"]
    =<< gettersRun optimizedRevision MinimizeLatency
  assertEqual
    "fully consistent reads only the head revision"
    ["getHead"]
    =<< gettersRun optimizedRevision FullyConsistent
  assertEqual
    "at exact snapshot reads only the horizon, never a revision"
    ["getNow", "getHorizon"]
    =<< gettersRun optimizedRevision (AtExactSnapshot (encodeToken payload))
  assertEqual
    "at least as fresh reads the horizon and the optimized revision, never head"
    ["getNow", "getHorizon", "getOptimized"]
    =<< gettersRun optimizedRevision (AtLeastAsFresh (encodeToken payload))
  assertEqual
    "a token that fails to decode fetches nothing at all"
    []
    =<< gettersRun optimizedRevision (AtExactSnapshot (ConsistencyToken "en1.primary.schema.bad"))
  assertEqual
    "wrong datastore is rejected"
    (Left (InvalidConsistencyToken "token datastore does not match this en datastore"))
    (validateTokenMetadata config now 0 metadataWithWrongDatastore)
  assertEqual
    "wrong schema hash is rejected"
    (Left (InvalidConsistencyToken "token schema hash does not match the active schema"))
    (validateTokenMetadata config now 0 metadataWithWrongSchema)
  assertEqual
    "expired token is rejected"
    (Left (ConsistencyTokenExpired "token is expired"))
    (validateTokenMetadata config now 0 expiredMetadata)
  assertEqual
    "token older than GC horizon is rejected"
    (Left (ConsistencyTokenExpired "token is older than the garbage-collection window"))
    (validateTokenMetadata config now 20 metadata)
  {- The reported bug: a token minted from a head revision on an idle store has
  @xmax == horizon@ and no in-flight transaction below the horizon, so every
  transaction below it is visible and nothing reaped is live. The old
  @xmax <= horizon@ rule refused it; 'retainedHistoryVisible' accepts it. -}
  assertEqual
    "a head-revision token whose xmax equals the horizon is accepted"
    (Right ())
    (validateTokenMetadata config now 27807 (metadataAtRevision (Revision "27807:27807:")))
  {- The converse the fix must not sacrifice: a snapshot with an in-flight
  transaction below the horizon (@849@ at horizon @850@) names a row that may
  already be reaped, so it is still refused even though its @xmax@ exceeds the
  horizon. -}
  assertEqual
    "a token with an in-flight transaction below the horizon is still rejected"
    (Left (ConsistencyTokenExpired "token is older than the garbage-collection window"))
    (validateTokenMetadata config now 850 (metadataAtRevision (Revision "849:851:849")))

  -- 'retainedHistoryVisible' boundaries, stated directly.
  assertEqual
    "retainedHistoryVisible accepts horizon == xmax"
    True
    (retainedHistoryVisible 20 PgSnapshot {xmin = 10, xmax = 20, xip = []})
  assertEqual
    "retainedHistoryVisible refuses horizon == xmax + 1"
    False
    (retainedHistoryVisible 21 PgSnapshot {xmin = 10, xmax = 20, xip = []})
  assertEqual
    "retainedHistoryVisible refuses an xip entry at horizon - 1"
    False
    (retainedHistoryVisible 15 PgSnapshot {xmin = 10, xmax = 20, xip = [14]})
  assertEqual
    "retainedHistoryVisible accepts an xip entry at horizon"
    True
    (retainedHistoryVisible 15 PgSnapshot {xmin = 10, xmax = 20, xip = [15]})
  where
    config =
      ConsistencyConfig
        { datastoreId = DatastoreId "primary",
          schemaHash = SchemaHash "schema:hash",
          gcWindow = "24 hours"
        }
    now = parseUtc "2026-06-23T00:00:00Z"
    optimizedRevision = Revision "10:30:"
    headRevision = Revision "10:40:"
    metadata =
      TokenMetadata
        { token = ConsistencyToken "token",
          revision = Revision "10:20:12",
          datastoreId = DatastoreId "primary",
          schemaHash = SchemaHash "schema:hash",
          expiresAt = Nothing
        }
    metadataWithWrongDatastore =
      TokenMetadata
        { token = metadata.token,
          revision = metadata.revision,
          datastoreId = DatastoreId "other",
          schemaHash = metadata.schemaHash,
          expiresAt = metadata.expiresAt
        }
    metadataWithWrongSchema =
      TokenMetadata
        { token = metadata.token,
          revision = metadata.revision,
          datastoreId = metadata.datastoreId,
          schemaHash = SchemaHash "other",
          expiresAt = metadata.expiresAt
        }
    expiredMetadata =
      TokenMetadata
        { token = metadata.token,
          revision = metadata.revision,
          datastoreId = metadata.datastoreId,
          schemaHash = metadata.schemaHash,
          expiresAt = Just now
        }
    metadataAtRevision rev =
      TokenMetadata
        { token = metadata.token,
          revision = rev,
          datastoreId = metadata.datastoreId,
          schemaHash = metadata.schemaHash,
          expiresAt = metadata.expiresAt
        }
    metadataFromToken token =
      case decodeToken token of
        Right tokenPayload ->
          Right
            TokenMetadata
              { token = token,
                revision = tokenPayload.revision,
                datastoreId = tokenPayload.datastoreId,
                schemaHash = tokenPayload.schemaHash,
                expiresAt = tokenPayload.expiresAt
              }
        Left err -> Left (MalformedConsistencyToken (renderTokenDecodeError err))

    -- \| A 'ResolveEnv' over 'IO' that appends each getter's name as it runs.
    --
    --    Standing in for the writer monad the plan sketched: what is being tested is a
    --    side effect (which getters ran), so the env has to be able to have one.
    --
    recordingEnv optimized ref =
      ResolveEnv
        { getOptimized = record ref "getOptimized" >> pure optimized,
          getHead = record ref "getHead" >> pure headRevision,
          getHorizon = record ref "getHorizon" >> pure 0,
          getNow = record ref "getNow" >> pure now
        }
    record ref name =
      modifyIORef' ref (<> [name :: Text.Text])

    runResolve optimized request = do
      ref <- newIORef []
      resolved <- resolveConsistencyRequest (recordingEnv optimized ref) metadataFromToken (validateTokenMetadata config) request
      getters <- readIORef ref
      pure (resolved, getters)

    resolve optimized request =
      fst <$> runResolve optimized request

    gettersRun optimized request =
      snd <$> runResolve optimized request

-- | The watch cursor's codec and its two fail-closed guards.
--
-- The codec is pure, so everything a cursor can be wrong about — the wrong store, a window
-- whose history is gone, a shape the store never minted — is checkable without a database.
-- That matters because the expiry path is otherwise reachable only by outwaiting a real
-- garbage-collection window.
testWatchCursorCodec :: IO ()
testWatchCursorCodec = do
  let datastore = DatastoreId "watch-datastore"
      other = DatastoreId "someone-elses-datastore"
      config =
        ConsistencyConfig
          { datastoreId = datastore,
            schemaHash = SchemaHash "schema",
            gcWindow = "24 hours"
          }
      start = Revision "100:120:110"
      end = Revision "120:140:"
      atStart = WatchAt start
      draining = WatchDraining start end (StoreCursor "4242")
      roundTrip cursorState = decodeWatchCursor (encodeWatchCursor datastore cursorState)

  assertEqual
    "a between-windows cursor round-trips"
    (Right (datastore, atStart))
    (roundTrip atStart)
  assertEqual
    "a mid-drain cursor round-trips both window edges and the row"
    (Right (datastore, draining))
    (roundTrip draining)

  -- A datastore id holding the codec's own separator survives it, which is what the
  -- percent-escaping is for. Unescaped, this would decode as a seven-field cursor.
  let dotted = DatastoreId "en.prod.1"
  assertEqual
    "a datastore id containing the field separator round-trips"
    (Right (dotted, atStart))
    (decodeWatchCursor (encodeWatchCursor dotted atStart))

  assertEqual
    "a consistency token is not a watch cursor"
    (Left (InvalidCursor "en1.store.schema.100:120:.") :: Either EnError (DatastoreId, WatchCursorState))
    (decodeWatchCursor "en1.store.schema.100:120:.")
  assertEqual
    "a cursor with the wrong prefix is refused"
    (Left (InvalidCursor "enwatch2.store.at.100:120:..") :: Either EnError (DatastoreId, WatchCursorState))
    (decodeWatchCursor "enwatch2.store.at.100:120:..")
  assertEqual
    "a cursor whose revision is not a snapshot is refused"
    (Left (InvalidCursor "enwatch1.store.at.not-a-snapshot..") :: Either EnError (DatastoreId, WatchCursorState))
    (decodeWatchCursor "enwatch1.store.at.not-a-snapshot..")
  {- A drain cursor with no row id would resume the window from its start on every poll,
  redelivering the first page forever. A between-windows cursor carrying one describes a
  position in a window it does not name. Both are shapes this codec never emits. -}
  assertEqual
    "a drain cursor with no row id is refused"
    (Left (InvalidCursor "enwatch1.store.drain.100:120:.120:140:.") :: Either EnError (DatastoreId, WatchCursorState))
    (decodeWatchCursor "enwatch1.store.drain.100:120:.120:140:.")
  assertEqual
    "a between-windows cursor carrying a row id is refused"
    (Left (InvalidCursor "enwatch1.store.at.100:120:..7") :: Either EnError (DatastoreId, WatchCursorState))
    (decodeWatchCursor "enwatch1.store.at.100:120:..7")

  -- Horizon 0: nothing has been reaped, so every window is still replayable.
  assertEqual
    "a cursor from this datastore validates while its history survives"
    (Right atStart)
    (validateWatchCursor config 0 datastore atStart)
  assertEqual
    "a cursor minted by another datastore is refused"
    (Left (InvalidConsistencyToken "watch cursor datastore does not match this en datastore"))
    (validateWatchCursor config 0 other atStart)
  {- The horizon is compared against the window /start/, not its end: the deletions a
  drain still owes happened at revisions between the two, and it is the start that says
  how far back the feed must be able to see. -}
  assertEqual
    "a cursor whose window opens behind the garbage-collection horizon is refused"
    (Left (ConsistencyTokenExpired "watch cursor is older than the garbage-collection window"))
    (validateWatchCursor config 120 datastore atStart)
  assertEqual
    "a mid-drain cursor is judged on its window start, not its end"
    (Left (ConsistencyTokenExpired "watch cursor is older than the garbage-collection window"))
    (validateWatchCursor config 120 datastore draining)

  {- A watch cursor is now judged by the identical predicate a consistency token is —
  'En.Postgres.Revision.retainedHistoryVisible', at the identical horizon — so the two no
  longer diverge on the horizon. 'start' below is @100:120:110@: @xmin = 100@, @xmax = 120@,
  with @110@ in flight.

  Every transaction below the horizon must be visible in the window's start snapshot. The
  in-flight @110@ is invisible there, so a horizon above @110@ names a row (one deleted at
  @110@) that could already be reaped while still live at the start — and is refused. A
  horizon at or below @110@ is accepted. This retires @docs/plans/53@'s conservative
  @horizon <= start.xmin@ rule: a horizon of @101@, which that rule refused, is accepted
  now, because @101@ is still visible in the start snapshot and nothing reaped below it is
  live there. -}
  assertEqual
    "a horizon at the window start's xmin is accepted"
    (Right atStart)
    (validateWatchCursor config 100 datastore atStart)
  assertEqual
    "a horizon one past the start's xmin is accepted now, where the old conservative rule refused it"
    (Right atStart)
    (validateWatchCursor config 101 datastore atStart)
  assertEqual
    "a horizon at the in-flight transaction is accepted"
    (Right atStart)
    (validateWatchCursor config 110 datastore atStart)
  assertEqual
    "a horizon just past the in-flight transaction is refused"
    (Left (ConsistencyTokenExpired "watch cursor is older than the garbage-collection window"))
    (validateWatchCursor config 111 datastore atStart)

assertEqual :: (Eq a, Show a) => String -> a -> a -> IO ()
assertEqual label expected actual
  | expected == actual = pure ()
  | otherwise =
      fail $
        label
          <> "\nexpected: "
          <> show expected
          <> "\nactual:   "
          <> show actual

parseUtc :: String -> UTCTime
parseUtc =
  parseTimeOrError True defaultTimeLocale "%Y-%m-%dT%H:%M:%SZ"

testOptimizedRevisionReader :: IO ()
testOptimizedRevisionReader = do
  baseTime <- pure (parseUtc "2026-06-23T00:00:00Z")
  clockRef <- newIORef baseTime
  callsRef <- newIORef (0 :: Int)
  cachedReader <-
    newOptimizedRevisionReader
      OptimizedRevisionConfig {enabled = True, ttl = 10}
      (readIORef clockRef)
      (nextRevision callsRef)
  first <- cachedReader
  second <- cachedReader
  assertEqual "optimized revision cache reuses within ttl" first second
  assertEqual "optimized revision cache reads once within ttl" 1 =<< readIORef callsRef
  writeIORef clockRef (addUTCTime 11 baseTime)
  third <- cachedReader
  assertEqual "optimized revision cache refreshes after ttl" (Revision "10:22:") third
  assertEqual "optimized revision cache increments after expiry" 2 =<< readIORef callsRef

  disabledCallsRef <- newIORef (0 :: Int)
  disabledReader <-
    newOptimizedRevisionReader
      OptimizedRevisionConfig {enabled = False, ttl = 10}
      (readIORef clockRef)
      (nextRevision disabledCallsRef)
  disabledFirst <- disabledReader
  disabledSecond <- disabledReader
  assertEqual "disabled optimized revision cache returns fresh first revision" (Revision "10:21:") disabledFirst
  assertEqual "disabled optimized revision cache returns fresh second revision" (Revision "10:22:") disabledSecond
  assertEqual "disabled optimized revision cache reads every time" 2 =<< readIORef disabledCallsRef

nextRevision :: IORef Int -> IO Revision
nextRevision callsRef = do
  modifyIORef' callsRef (+ 1)
  calls <- readIORef callsRef
  pure (Revision ("10:" <> Text.pack (show (20 + calls)) <> ":"))
