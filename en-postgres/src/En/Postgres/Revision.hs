{-# LANGUAGE BlockArguments #-}
{-# LANGUAGE DuplicateRecordFields #-}
{-# LANGUAGE NoFieldSelectors #-}

-- | PostgreSQL @pg_snapshot@ revisions and consistency-token codec.
module En.Postgres.Revision (
    PgSnapshot (..),
    TokenPayload (..),
    TokenDecodeError (..),
    ConsistencyConfig (..),
    OptimizedRevisionConfig (..),
    TtlCache,
    OptimizedRevisionCache,
    ResolveEnv (..),
    parsePgSnapshot,
    renderPgSnapshot,
    revisionFromPgSnapshot,
    revisionToPgSnapshot,
    newTtlCache,
    lookupTtlCache,
    storeTtlCache,
    newOptimizedRevisionCache,
    lookupOptimizedRevisionCache,
    storeOptimizedRevisionCache,
    newOptimizedRevisionReader,
    transactionVisible,
    retainedHistoryVisible,
    snapshotIncludes,
    comparePgSnapshot,
    comparePostgresRevision,
    encodeToken,
    decodeToken,
    renderTokenDecodeError,
    tokenMetadataFromPayload,
    validateTokenMetadata,
    resolveConsistencyRequest,
    runConsistencyStorePostgres,
    escapeText,
    unescapeText,
) where

import Data.Char (digitToInt, isDigit, ord)
import Data.IORef (IORef, newIORef, readIORef, writeIORef)
import Data.List (nub, sort)
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Time (NominalDiffTime, UTCTime, diffUTCTime, getCurrentTime)
import Data.Time.Format.ISO8601 (iso8601ParseM, iso8601Show)
import Data.Word (Word64)
import Effectful (Eff, IOE, liftIO, (:>))
import Effectful.Dispatch.Dynamic (interpret_)
import Effectful.Error.Static (Error, throwError)
import Numeric (readDec, showHex)

import En.Effect.ConsistencyStore (
    ConsistencyStore (..),
    ResolvedConsistency (..),
    TokenMetadata (..),
 )
import En.Effect.TupleStore (TupleStore)
import En.Effect.TupleStore qualified as TupleStore
import En.Error (EnError (..))
import En.Revision (
    Consistency (..),
    ConsistencyToken (..),
    DatastoreId (..),
    Revision (..),
    RevisionOrder (..),
    SchemaHash (..),
 )

-- | A PostgreSQL MVCC snapshot, rendered as @xmin:xmax:xip1,xip2,...@.
data PgSnapshot = PgSnapshot
    { xmin :: !Word64
    , xmax :: !Word64
    , xip :: ![Word64]
    }
    deriving stock (Eq, Show)

data TokenPayload = TokenPayload
    { datastoreId :: !DatastoreId
    , schemaHash :: !SchemaHash
    , revision :: !Revision
    , expiresAt :: !(Maybe UTCTime)
    }
    deriving stock (Eq, Show)

data ConsistencyConfig = ConsistencyConfig
    { datastoreId :: !DatastoreId
    , schemaHash :: !SchemaHash
    , gcWindow :: !Text
    }
    deriving stock (Eq, Show)

data OptimizedRevisionConfig = OptimizedRevisionConfig
    { enabled :: !Bool
    , ttl :: !NominalDiffTime
    }
    deriving stock (Eq, Show)

{- | A single-cell cache whose entry expires once older than the configured TTL.

Polymorphic so a second value type can ride the same mechanism, but note what
'OptimizedRevisionConfig' means before instantiating it for anything but a
revision. Its TTL answers "how stale may this value be", and staleness is only
benign when a stale value is /more/ conservative than a fresh one. That holds for
the optimized revision — reading at an older snapshot returns older data, which is
exactly what 'MinimizeLatency' asks for.

It does /not/ hold for the garbage-collection horizon
('En.Effect.TupleStore.oldestRetainedXid'), which is why the horizon is not cached
here. See the 2026-07-09 Decision Log entry in
@docs/plans/49-trim-dead-indexes-and-resolve-consistency-lazily.md@: the horizon is
monotone non-decreasing — a durable high-water mark, @en_gc_horizon@, holds it there
(@docs/plans/60@ Milestone 4, which found the raw @coalesce@ query is /not/ monotone
on its own and clamps it up to the mark). 'validateTokenMetadata' rejects a token
unless 'retainedHistoryVisible' holds of the horizon, and that predicate is /easier/
to satisfy for a smaller horizon, so a stale (smaller) horizon accepts /more/ tokens
— it honours tokens whose history the reaper has already destroyed. A TTL on the
horizon is a TTL on how long an expired token keeps working.
-}
data TtlCache a = TtlCache
    { config :: !OptimizedRevisionConfig
    , clock :: !(IO UTCTime)
    , state :: !(IORef (Maybe (CachedValue a)))
    }

data CachedValue a = CachedValue
    { value :: !a
    , loadedAt :: !UTCTime
    }

-- | The 'Revision' instantiation of 'TtlCache', the only one in the tree.
type OptimizedRevisionCache = TtlCache Revision

{- | Why a token failed to decode. Internal to this module; its 'Show' is for the
operator's logs. A client is shown 'renderTokenDecodeError' instead, because the two
audiences want different text and a constructor name must never reach the wire.
-}
data TokenDecodeError
    = TokenBadPrefix
    | TokenBadFieldCount
    | TokenBadEscape Text
    | TokenBadSnapshot Text
    | TokenBadExpiry Text
    deriving stock (Eq, Show)

{- | A token-decode failure, rendered for the client that sent the token.

Deliberately not the 'Show' instance: 'Show' names the constructor for an operator
reading a log, and this names the fault for a caller reading an HTTP body. The
offending token is not echoed back — a caller that sent it already has it, and an
operator does not need it twice.
-}
renderTokenDecodeError :: TokenDecodeError -> Text
renderTokenDecodeError = \case
    TokenBadPrefix -> "not an en consistency token"
    TokenBadFieldCount -> "consistency token is truncated or has extra fields"
    TokenBadEscape _ -> "consistency token contains an invalid escape sequence"
    TokenBadSnapshot _ -> "consistency token does not carry a PostgreSQL snapshot"
    TokenBadExpiry _ -> "consistency token has an unparseable expiry"

parsePgSnapshot :: Text -> Either Text PgSnapshot
parsePgSnapshot input =
    case Text.splitOn ":" input of
        [xminText, xmaxText, xipText] -> do
            parsedXmin <- parseWord "xmin" xminText
            parsedXmax <- parseWord "xmax" xmaxText
            parsedXip <-
                if Text.null xipText
                    then Right []
                    else traverse (parseWord "xip") (Text.splitOn "," xipText)
            if parsedXmin > parsedXmax
                then Left "xmin must be <= xmax"
                else Right PgSnapshot{xmin = parsedXmin, xmax = parsedXmax, xip = sort (nub parsedXip)}
        _ -> Left "pg_snapshot must have xmin:xmax:xip shape"

renderPgSnapshot :: PgSnapshot -> Text
renderPgSnapshot PgSnapshot{xmin, xmax, xip} =
    Text.pack (show xmin)
        <> ":"
        <> Text.pack (show xmax)
        <> ":"
        <> Text.intercalate "," (Text.pack . show <$> sort (nub xip))

revisionFromPgSnapshot :: PgSnapshot -> Revision
revisionFromPgSnapshot =
    Revision . renderPgSnapshot

revisionToPgSnapshot :: Revision -> Either Text PgSnapshot
revisionToPgSnapshot =
    parsePgSnapshot . revisionEncoding

newTtlCache :: OptimizedRevisionConfig -> IO UTCTime -> IO (TtlCache a)
newTtlCache config clock = do
    state <- newIORef Nothing
    pure TtlCache{config, clock, state}

lookupTtlCache :: TtlCache a -> IO (Maybe a)
lookupTtlCache cache
    | not cache.config.enabled || cache.config.ttl <= 0 = pure Nothing
    | otherwise = do
        now <- cache.clock
        cached <- readIORef cache.state
        pure do
            entry <- cached
            if diffUTCTime now entry.loadedAt <= cache.config.ttl
                then Just entry.value
                else Nothing

storeTtlCache :: TtlCache a -> a -> IO ()
storeTtlCache cache value
    | not cache.config.enabled || cache.config.ttl <= 0 = pure ()
    | otherwise = do
        now <- cache.clock
        writeIORef cache.state (Just CachedValue{value, loadedAt = now})

newOptimizedRevisionCache :: OptimizedRevisionConfig -> IO UTCTime -> IO OptimizedRevisionCache
newOptimizedRevisionCache =
    newTtlCache

lookupOptimizedRevisionCache :: OptimizedRevisionCache -> IO (Maybe Revision)
lookupOptimizedRevisionCache =
    lookupTtlCache

storeOptimizedRevisionCache :: OptimizedRevisionCache -> Revision -> IO ()
storeOptimizedRevisionCache =
    storeTtlCache

newOptimizedRevisionReader ::
    OptimizedRevisionConfig ->
    IO UTCTime ->
    IO Revision ->
    IO (IO Revision)
newOptimizedRevisionReader config clock readFresh = do
    cache <- newOptimizedRevisionCache config clock
    pure do
        cached <- lookupOptimizedRevisionCache cache
        case cached of
            Just revision -> pure revision
            Nothing -> do
                revision <- readFresh
                storeOptimizedRevisionCache cache revision
                pure revision

{- | Whether a transaction id is visible in a snapshot, mirroring PostgreSQL's
@pg_visible_in_snapshot@ rules for committed transaction ids.
-}
transactionVisible :: Word64 -> PgSnapshot -> Bool
transactionVisible txid PgSnapshot{xmin, xmax, xip}
    | txid < xmin = True
    | txid >= xmax = False
    | otherwise = txid `notElem` xip

{- | Is every transaction id below @horizon@ visible in @snapshot@?

This is the exact garbage-collection safety condition, and it is the one predicate
that governs both consistency-token validation ('validateTokenMetadata') and watch
cursors ('En.Postgres.Watch.validateWatchCursor'). Both ask the identical question of
the identical horizon, so they answer it with the identical function.

== Why this is the right question

@horizon@ is @oldestRetainedXid@: the reaper physically deletes a soft-deleted row
only when its @deleted_xid < horizon@ (@reapDeletedTuplesStatement@ in
"En.Postgres.TupleStore"). Such a reaped row is dangerous to a reader at snapshot @S@
only if it is still /live/ at @S@ — that is, if its deletion is __not__ visible in @S@.

If every transaction below @horizon@ is visible in @S@, then every reaped row's
deletion (which happened below @horizon@) is visible in @S@, so no reaped row is live
at @S@, so @S@ can be served exactly from the surviving rows. (A reaped row's creation
is older than its deletion, hence visible too; it therefore contributes nothing at @S@
in either direction.) Conversely, if some @t < horizon@ is invisible in @S@, a row
deleted at @t@ is live at @S@ and may already be gone, so @S@ must be refused.

== Why the enumeration collapses to two clauses

\"Every @t < horizon@ is visible in @S@\" is @all (\\t -> transactionVisible t S)
[0 .. horizon - 1]@. A transaction @t@ is invisible in @S@ exactly when @t >= S.xmax@,
or when @S.xmin <= t < S.xmax@ and @t@ is listed in @S.xip@. So the enumeration holds
iff no invisible transaction sits below the horizon:

  * No @t@ with @t >= S.xmax@ is below the horizon — i.e. @horizon <= S.xmax@.
  * No @xip@ entry in @[S.xmin, S.xmax)@ is below the horizon — i.e. every @xip@ entry
    is either below @S.xmin@ (visible, so harmless) or at/above @horizon@.

which is exactly

@
retainedHistoryVisible horizon snapshot =
    horizon <= snapshot.xmax
        && all (\\txid -> txid < snapshot.xmin || txid >= horizon) snapshot.xip
@

The second clause skips @xip@ entries below @xmin@: 'transactionVisible' already
reports those visible, and a real @pg_snapshot@ never carries them, but 'parsePgSnapshot'
accepts them and this predicate must agree with 'transactionVisible', not with
PostgreSQL's invariants.

== Why the old @snapshot.xmax <= horizon@ rule could not simply be adjusted

It errs in both directions, so no tightening or loosening of the comparison recovers it:

  * It rejects @27807:27807:@ at horizon @27807@ (@xmax == horizon@) — yet every
    transaction below @27807@ is visible, nothing reaped is live, and the snapshot is
    safe. This is the reported bug: a @checkedAt@ token minted from a head revision on
    an idle store is refused the instant it is spent.
  * It accepts @849:851:849@ at horizon @850@ (@xmax > horizon@) — yet @849@ is
    in-flight and therefore invisible, so a row deleted at @849@ is live at the
    snapshot and reapable, and the reader would be served a snapshot missing a grant it
    should see.

Only asking the exact question answers both.
-}
retainedHistoryVisible :: Word64 -> PgSnapshot -> Bool
retainedHistoryVisible horizon snapshot =
    horizon <= snapshot.xmax
        && all (\txid -> txid < snapshot.xmin || txid >= horizon) snapshot.xip

comparePgSnapshot :: PgSnapshot -> PgSnapshot -> RevisionOrder
comparePgSnapshot left right =
    case (snapshotIncludes left right, snapshotIncludes right left) of
        (True, True) -> REqual
        (True, False) -> RAfter
        (False, True) -> RBefore
        (False, False) -> RConcurrent

comparePostgresRevision :: Revision -> Revision -> Either Text RevisionOrder
comparePostgresRevision left right =
    comparePgSnapshot <$> revisionToPgSnapshot left <*> revisionToPgSnapshot right

encodeToken :: TokenPayload -> ConsistencyToken
encodeToken TokenPayload{datastoreId, schemaHash, revision, expiresAt} =
    ConsistencyToken $
        Text.intercalate
            "."
            [ "en1"
            , escapeText datastoreText
            , escapeText schemaHashText
            , escapeText revisionText
            , maybe "" (escapeText . Text.pack . iso8601Show) expiresAt
            ]
  where
    DatastoreId datastoreText = datastoreId
    SchemaHash schemaHashText = schemaHash
    revisionText = revisionEncoding revision

decodeToken :: ConsistencyToken -> Either TokenDecodeError TokenPayload
decodeToken (ConsistencyToken tokenText) =
    case Text.splitOn "." tokenText of
        ["en1", datastoreText, schemaText, revisionText, expiresText] -> do
            datastore <- unescapeText datastoreText
            schema <- unescapeText schemaText
            revision <- unescapeText revisionText
            expires <- traverse parseExpiry (nonEmptyText expiresText)
            case parsePgSnapshot revision of
                Left err -> Left (TokenBadSnapshot err)
                Right _ ->
                    Right
                        TokenPayload
                            { datastoreId = DatastoreId datastore
                            , schemaHash = SchemaHash schema
                            , revision = Revision revision
                            , expiresAt = expires
                            }
        prefix : _ | prefix /= "en1" -> Left TokenBadPrefix
        _ -> Left TokenBadFieldCount

tokenMetadataFromPayload :: ConsistencyToken -> Either EnError TokenMetadata
tokenMetadataFromPayload token =
    case decodeToken token of
        Left err -> Left (MalformedConsistencyToken (renderTokenDecodeError err))
        Right payload ->
            Right
                TokenMetadata
                    { token = token
                    , revision = payload.revision
                    , datastoreId = payload.datastoreId
                    , schemaHash = payload.schemaHash
                    , expiresAt = payload.expiresAt
                    }

validateTokenMetadata :: ConsistencyConfig -> UTCTime -> Word64 -> TokenMetadata -> Either EnError ()
validateTokenMetadata config now oldestRetainedXid metadata
    | metadata.datastoreId /= config.datastoreId =
        Left (InvalidConsistencyToken "token datastore does not match this en datastore")
    | metadata.schemaHash /= config.schemaHash =
        Left (InvalidConsistencyToken "token schema hash does not match the active schema")
    | maybe False (<= now) metadata.expiresAt =
        Left (ConsistencyTokenExpired "token is expired")
    | otherwise = do
        snapshot <-
            mapLeft
                (MalformedConsistencyToken . ("token revision is not a PostgreSQL snapshot: " <>))
                (revisionToPgSnapshot metadata.revision)
        if retainedHistoryVisible oldestRetainedXid snapshot
            then Right ()
            else Left (ConsistencyTokenExpired "token is older than the garbage-collection window")

{- | The four things a consistency mode might need, each fetched on demand.

Every field is an action rather than a value, which is the whole point: no mode
needs all four, and 'ResolveConsistency' used to fetch three of them
unconditionally — three sequential round trips per read, on a pool whose
connections are shared. Making the inputs lazy by construction keeps the
mode-to-requirement mapping in 'resolveConsistencyRequest', where it can be read
and unit-tested, instead of duplicating a @case@ in the interpreter.
-}
data ResolveEnv m = ResolveEnv
    { getOptimized :: m Revision
    , getHead :: m Revision
    , getHorizon :: m Word64
    , getNow :: m UTCTime
    }

{- | Resolve a consistency request, fetching only what the mode demands.

The revision each mode selects is unchanged; only the fetching moved. Per mode:

* @MinimizeLatency@ runs @getOptimized@ alone.
* @FullyConsistent@ runs @getHead@ alone.
* @AtExactSnapshot@ decodes the token, then runs @getNow@ and @getHorizon@ to
  validate it. It never reads the optimized or head revision — the token /is/ the
  answer.
* @AtLeastAsFresh@ decodes and validates as above, then runs @getOptimized@ for the
  comparison. It never reads head.

A token-less request therefore performs no horizon fetch and no token validation:
the horizon exists only to reject tokens older than retained history, and there is
no token to reject.
-}
resolveConsistencyRequest ::
    (Monad m) =>
    ResolveEnv m ->
    (ConsistencyToken -> Either EnError TokenMetadata) ->
    (UTCTime -> Word64 -> TokenMetadata -> Either EnError ()) ->
    Consistency ->
    m (Either EnError ResolvedConsistency)
resolveConsistencyRequest env decode validate request =
    case request of
        MinimizeLatency ->
            resolvedAt <$> env.getOptimized
        FullyConsistent ->
            resolvedAt <$> env.getHead
        AtExactSnapshot token ->
            withValidToken token \metadata ->
                pure (resolvedAt metadata.revision)
        AtLeastAsFresh token ->
            withValidToken token \metadata -> do
                optimized <- env.getOptimized
                pure (freshestOf optimized metadata.revision)
  where
    resolvedAt revision =
        Right ResolvedConsistency{consistency = request, revision}

    freshestOf optimized tokenRevision = do
        order <-
            mapLeft
                (InvalidConsistencyToken . ("could not compare token revision: " <>))
                (comparePostgresRevision optimized tokenRevision)
        resolvedAt case order of
            RAfter -> optimized
            REqual -> optimized
            RBefore -> tokenRevision
            RConcurrent -> tokenRevision

    withValidToken token continue =
        case decode token of
            Left err -> pure (Left err)
            Right metadata -> do
                now <- env.getNow
                horizon <- env.getHorizon
                case validate now horizon metadata of
                    Left err -> pure (Left err)
                    Right () -> continue metadata

runConsistencyStorePostgres ::
    (TupleStore :> es, IOE :> es, Error EnError :> es) =>
    ConsistencyConfig ->
    Eff (ConsistencyStore : es) a ->
    Eff es a
runConsistencyStorePostgres config =
    interpret_ \case
        DecodeToken token ->
            either throwError pure (tokenMetadataFromPayload token)
        ValidateToken metadata -> do
            now <- liftIO getCurrentTime
            oldestXid <- TupleStore.oldestRetainedXid
            either throwError pure (validateTokenMetadata config now oldestXid metadata)
        -- Each getter is one database session, so the fetches 'resolveConsistencyRequest'
        -- forces are the round trips this request pays: one for 'MinimizeLatency',
        -- 'FullyConsistent' and 'AtExactSnapshot', two for 'AtLeastAsFresh'.
        ResolveConsistency request -> do
            let env =
                    ResolveEnv
                        { getOptimized = TupleStore.optimizedRevision
                        , getHead = TupleStore.headRevision
                        , getHorizon = TupleStore.oldestRetainedXid
                        , getNow = liftIO getCurrentTime
                        }
            resolved <-
                resolveConsistencyRequest
                    env
                    tokenMetadataFromPayload
                    (validateTokenMetadata config)
                    request
            either throwError pure resolved
        -- 'expiresAt' is 'Nothing', exactly as write tokens are minted
        -- ('En.Postgres.TupleStore.tokenFromAnchor'). The garbage-collection
        -- window is not a wall-clock stamp on the token; it is enforced at
        -- validation time by comparing the token's snapshot against
        -- 'oldestRetainedXid'. A minted token therefore expires when the rows it
        -- could read are reaped, which is the property that matters.
        MintToken revision ->
            pure
                ( encodeToken
                    TokenPayload
                        { datastoreId = config.datastoreId
                        , schemaHash = config.schemaHash
                        , revision
                        , expiresAt = Nothing
                        }
                )

snapshotIncludes :: PgSnapshot -> PgSnapshot -> Bool
snapshotIncludes candidate required =
    not (hasRequiredVisibleFutureGap candidate required)
        && all
            (\txid -> not (transactionVisible txid required))
            (filter (< required.xmax) candidate.xip)

hasRequiredVisibleFutureGap :: PgSnapshot -> PgSnapshot -> Bool
hasRequiredVisibleFutureGap candidate required =
    candidate.xmax < required.xmax
        && not (rangeFullyCoveredByXip candidate.xmax required.xmax required.xip)

rangeFullyCoveredByXip :: Word64 -> Word64 -> [Word64] -> Bool
rangeFullyCoveredByXip lower upper xip =
    let covered =
            length
                [ txid
                | txid <- nub xip
                , txid >= lower
                , txid < upper
                ]
        rangeLength =
            toInteger upper - toInteger lower
     in rangeLength == toInteger covered

parseExpiry :: Text -> Either TokenDecodeError UTCTime
parseExpiry text =
    case iso8601ParseM (Text.unpack text) of
        Just value -> Right value
        Nothing -> Left (TokenBadExpiry text)

parseWord :: Text -> Text -> Either Text Word64
parseWord fieldName textValue
    | Text.null textValue = Left (fieldName <> " is empty")
    | Text.any (not . isDigit) textValue = Left (fieldName <> " is not decimal")
    | otherwise =
        case readDec (Text.unpack textValue) of
            [(value, "")] -> Right value
            _ -> Left (fieldName <> " is not a Word64")

{- | Percent-escape everything that is not @[A-Za-z0-9_-]@.

Exported for "En.Postgres.Watch", whose cursor codec must escape its fields the same way
this module's token codec does: both split on @.@, so a field holding one would otherwise
be read as two.
-}
escapeText :: Text -> Text
escapeText =
    Text.concatMap
        ( \char ->
            if isTokenChar char
                then Text.singleton char
                else Text.pack ('%' : pad2 (showHex (ord char) ""))
        )

unescapeText :: Text -> Either TokenDecodeError Text
unescapeText text =
    Text.pack <$> go (Text.unpack text)
  where
    go [] = Right []
    go ('%' : a : b : rest)
        | isHex a && isHex b =
            let value = digitToInt a * 16 + digitToInt b
             in (toEnum value :) <$> go rest
    go ('%' : rest) = Left (TokenBadEscape (Text.pack ('%' : rest)))
    go (char : rest) = (char :) <$> go rest

isTokenChar :: Char -> Bool
isTokenChar char =
    char >= 'a' && char <= 'z'
        || char >= 'A' && char <= 'Z'
        || char >= '0' && char <= '9'
        || char == '-'
        || char == '_'

isHex :: Char -> Bool
isHex char =
    char >= '0' && char <= '9'
        || char >= 'a' && char <= 'f'
        || char >= 'A' && char <= 'F'

pad2 :: String -> String
pad2 [char] = ['0', char]
pad2 chars = chars

nonEmptyText :: Text -> Maybe Text
nonEmptyText text
    | Text.null text = Nothing
    | otherwise = Just text

mapLeft :: (left -> left') -> Either left right -> Either left' right
mapLeft f =
    either (Left . f) Right
