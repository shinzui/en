{-# LANGUAGE BlockArguments #-}
{-# LANGUAGE DuplicateRecordFields #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE NoFieldSelectors #-}

{- | The PostgreSQL watch feed: a cursored poll over the changelog
'En.Effect.TupleStore.ReadChanges' exposes.

One poll answers "what changed between where you were and where the store is now", and
hands back a cursor to resume from. The cursor is the whole contract, so most of this
module is its codec and its validation.

Why a cursor and not a token. Between two polls the feed may be mid-window: a window with
more changes than one page can carry must be drained across several polls, and every one of
them must read the /same/ window, or the batch stops being the set difference between two
snapshots and starts being a smear across several. So the cursor carries a window's two
edges and a position inside it — more than an @en1.@ consistency token can hold. This is
also why a resuming poll never re-resolves anything: both edges come from the cursor.
-}
module En.Postgres.Watch (
    WatchCursorState (..),
    encodeWatchCursor,
    decodeWatchCursor,
    validateWatchCursor,
    watch,
) where

import Data.Text (Text)
import Data.Text qualified as Text
import Data.Word (Word64)
import Effectful (Eff, (:>))
import Effectful.Error.Static (Error, throwError)

import En.Effect.ConsistencyStore (ConsistencyStore, TokenMetadata (..))
import En.Effect.ConsistencyStore qualified as ConsistencyStore
import En.Effect.TupleStore (ChangePage (..), PageState (..), RelationshipFilter, StoreCursor (..), TupleStore)
import En.Effect.TupleStore qualified as TupleStore
import En.Error (EnError (..))
import En.Postgres.Revision (
    ConsistencyConfig (..),
    PgSnapshot (..),
    escapeText,
    parsePgSnapshot,
    revisionToPgSnapshot,
    unescapeText,
 )
import En.Revision (ConsistencyToken (..), DatastoreId (..), Revision (..))
import En.Watch (WatchBatch (..), WatchStart (..))

{- | Where a consumer is in the feed.

'WatchAt' is between windows: the next window opens at this revision. 'WatchDraining' is
inside one: both edges are pinned, and the row id says how far through it the consumer has
read. Pinning the end edge is what makes a multi-page batch mean anything — a drain that
let the end advance would return a page from one snapshot pair and the next page from
another, with the rows in between belonging to neither.
-}
data WatchCursorState
    = WatchAt !Revision
    | WatchDraining !Revision !Revision !StoreCursor
    deriving stock (Eq, Show)

{- | The cursor codec: @enwatch1.\<datastore\>.\<tag\>.\<start\>.\<end\>.\<row\>@.

Six dot-separated, percent-escaped fields, exactly as the @en1.@ token codec renders its
five. It is deliberately not an @en1.@ token: a token names one revision, and a mid-drain
position needs two plus an offset. The unused fields of a 'WatchAt' cursor are empty rather
than omitted, so the field count alone tells a malformed cursor from a well-formed one.
-}
encodeWatchCursor :: DatastoreId -> WatchCursorState -> Text
encodeWatchCursor (DatastoreId datastoreId) cursorState =
    Text.intercalate
        "."
        [ watchCursorPrefix
        , escapeText datastoreId
        , tag
        , escapeText startText
        , escapeText endText
        , escapeText rowText
        ]
  where
    (tag, startText, endText, rowText) =
        case cursorState of
            WatchAt start ->
                ("at", start.revisionEncoding, "", "")
            WatchDraining start end (StoreCursor rowId) ->
                ("drain", start.revisionEncoding, end.revisionEncoding, rowId)

watchCursorPrefix :: Text
watchCursorPrefix = "enwatch1"

{- | Decode a cursor, or say it is not one this store issued.

Structural failures only: shape, escaping, and whether the revisions are PostgreSQL
snapshots. Whether the cursor belongs to /this/ datastore and still names replayable
history is 'validateWatchCursor''s question, because answering it needs the garbage
collection horizon, which needs a database round trip.

Every failure here is 'InvalidCursor' rather than 'InvalidConsistencyToken'. A cursor is a
pagination artifact and this is the fault of a client that presented one the store never
minted; restarting the scan in its place would silently redeliver the whole window.
-}
decodeWatchCursor :: Text -> Either EnError (DatastoreId, WatchCursorState)
decodeWatchCursor cursorText =
    case Text.splitOn "." cursorText of
        [prefix, datastoreField, tag, startField, endField, rowField]
            | prefix == watchCursorPrefix -> do
                datastoreId <- unescape datastoreField
                startText <- unescape startField
                endText <- unescape endField
                rowText <- unescape rowField
                start <- snapshotRevision startText
                case tag of
                    "at"
                        | Text.null endText
                        , Text.null rowText ->
                            Right (DatastoreId datastoreId, WatchAt start)
                    "drain"
                        | not (Text.null rowText) -> do
                            end <- snapshotRevision endText
                            Right (DatastoreId datastoreId, WatchDraining start end (StoreCursor rowText))
                    _ -> malformed
        _ -> malformed
  where
    malformed :: Either EnError a
    malformed = Left (InvalidCursor cursorText)

    unescape :: Text -> Either EnError Text
    unescape = either (const malformed) Right . unescapeText

    snapshotRevision :: Text -> Either EnError Revision
    snapshotRevision text =
        case parsePgSnapshot text of
            Left _ -> malformed
            Right _ -> Right (Revision text)

{- | The two fail-closed guards. Both differ from
'En.Postgres.Revision.validateTokenMetadata', and both differences are load-bearing.

The datastore check refuses a cursor minted elsewhere. It is the same check.

The horizon check refuses a window whose start lies behind what the reaper has already
destroyed: those rows are physically gone, so the set difference across the window cannot be
computed, and returning a partial one would tell a consumer its cache is up to date when it
is not. But the /condition/ is @horizon <= start.xmin@, where a token demands
@horizon < revision.xmax@. The window's condition is derivable, and the token's is not
sufficient here:

The reaper removes rows whose @deleted_xid < horizon@. A window starting at @S@ owes an
event about a row only if that row's membership differs between @S@ and the window's end,
which for a reaped row means its deletion must not be visible in @S@. If @horizon <= S.xmin@
then every reaped row has @deleted_xid < S.xmin@, hence is visible in @S@ by definition of
@xmin@, hence is not live at @S@; its creation is older still, so no touch is owed either.
Nothing reaped is ever owed, and the window is exact.

The token's @xmax@ rule does not give this. A snapshot @849:851:849@ has @xmax@ above a
horizon of @850@ and would pass it, yet lists @849@ in-progress — so a row deleted at @849@
is live at @S@, is below the horizon, and is reapable. The window would silently lose its
deletion. Conversely the @xmax@ rule is too strict at the other end: a subscription's cursor
is minted from 'TupleStore.headRevision', whose @xmax@ is the next unassigned xid, so the
first write after 'StartFromNow' pushes the horizon up to meet it and expires a feed one
poll old. Both failures are fixed by asking the question the window actually asks.

The schema hash is deliberately not checked at all. A tuple change is schema-independent
data. Expiring every watch consumer on a schema reload (see
@docs/plans/54-manage-the-schema-lifecycle-at-runtime.md@) would sever the revocation feed
at exactly the moment an operator changes the model — the moment it is most needed.
-}
validateWatchCursor :: ConsistencyConfig -> Word64 -> DatastoreId -> WatchCursorState -> Either EnError WatchCursorState
validateWatchCursor config oldestRetainedXid datastoreId cursorState
    | datastoreId /= config.datastoreId =
        Left (InvalidConsistencyToken "watch cursor datastore does not match this en datastore")
    | otherwise =
        case revisionToPgSnapshot (windowStart cursorState) of
            Left err ->
                Left (InvalidConsistencyToken ("watch cursor revision is not a PostgreSQL snapshot: " <> err))
            Right snapshot
                | snapshot.xmin < oldestRetainedXid ->
                    Left (InvalidConsistencyToken "watch cursor is older than the garbage-collection window")
                | otherwise ->
                    Right cursorState

windowStart :: WatchCursorState -> Revision
windowStart = \case
    WatchAt start -> start
    WatchDraining start _end _row -> start

{- | One poll of the feed.

Three shapes, one rule: the batch is always the set difference of the live tuple set across
a window whose edges this call fixes before it reads anything.

* 'StartFromNow' opens a window of zero width at the head. No changes, one cursor — the
  subscription's origin.
* 'WatchAt' takes the head as the window's end and drains its first page.
* 'WatchDraining' continues an already-fixed window and never consults the head at all.

The last is the cursored-read rule @docs/plans/51@ made load-bearing: a resuming read must
take its snapshot from the cursor and must not re-resolve anything, or successive pages of
one batch span two snapshots and the batch acquires gaps. Watch has no @consistency@ field
for exactly this reason — there is nothing to re-resolve.

@checkedAt@ is minted from the window's end, which is the snapshot the batch describes the
world at. A consumer can feed it straight back as @atLeastAsFresh@ and read a store that has
already applied every change it was just told about.
-}
watch ::
    (TupleStore :> es, ConsistencyStore :> es, Error EnError :> es) =>
    ConsistencyConfig ->
    WatchStart ->
    Maybe RelationshipFilter ->
    Int ->
    Eff es WatchBatch
watch config start relationshipFilter limit =
    resolveStart >>= \case
        Nothing -> do
            head' <- TupleStore.headRevision
            emptyBatch head'
        Just (WatchAt from) -> do
            end <- TupleStore.headRevision
            if end == from
                then emptyBatch end
                else drainWindow from end Nothing
        Just (WatchDraining from end lastRow) ->
            drainWindow from end (Just lastRow)
  where
    emptyBatch revision = do
        checkedAt <- ConsistencyStore.mintToken revision
        pure
            WatchBatch
                { changes = []
                , cursor = encodeWatchCursor config.datastoreId (WatchAt revision)
                , checkedAt
                }

    drainWindow from end cursor = do
        page <- TupleStore.readChanges from end relationshipFilter limit cursor
        checkedAt <- ConsistencyStore.mintToken end
        let next =
                case page.state of
                    Exhausted -> WatchAt end
                    HasMore resume -> WatchDraining from end resume
                    -- A store read spends no evaluation budget, so it cannot truncate.
                    -- Resuming the window from the cursor is right either way.
                    Truncated resume -> WatchDraining from end resume
        pure
            WatchBatch
                { changes = page.changes
                , cursor = encodeWatchCursor config.datastoreId next
                , checkedAt
                }

    -- 'Nothing' is "start from now": there is no window to reopen, only a head to name.
    resolveStart =
        case start of
            StartFromNow ->
                pure Nothing
            StartFromCursor cursorText -> do
                (datastoreId, cursorState) <- either throwError pure (decodeWatchCursor cursorText)
                oldestRetainedXid <- TupleStore.oldestRetainedXid
                validated <- either throwError pure (validateWatchCursor config oldestRetainedXid datastoreId cursorState)
                pure (Just validated)
            {- A real token, so it gets the real token validation — schema hash included.
            The exemption above is for cursors this module mints, not for artifacts minted
            elsewhere and handed to it. -}
            StartFromToken tokenText -> do
                metadata <- ConsistencyStore.decodeToken (ConsistencyToken tokenText)
                ConsistencyStore.validateToken metadata
                pure (Just (WatchAt metadata.revision))
