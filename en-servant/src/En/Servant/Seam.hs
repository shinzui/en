{-# LANGUAGE RankNTypes #-}

-- | The seam between en's effectful engine stack and servant's 'Handler'.
module En.Servant.Seam (
    AppEffects,
    ActiveSchema (..),
    Env (..),
    EnServer,
    ErrorEnvelopeWire (..),
    EnFault (..),
    enErrorToFault,
    badRequest,
    invalidRequest,
    batchTooLarge,
    permissionDenied,
    notFound,
    faultToServerError,
    envelopeError,
    runEngine,
    runEngineEither,
    enErrorToServerError,
) where

import Control.Monad.IO.Class (liftIO)
import Data.Aeson (FromJSON (..), ToJSON (..), encode, pairs, withObject, (.:), (.=))
import Data.Aeson qualified as Aeson
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Text.Encoding qualified as Text
import Data.Text.IO qualified as Text
import Data.Time (UTCTime)
import Effectful (Eff, IOE)
import Effectful.Error.Static (Error)
import Servant (Handler, ServerError (..), err400, err403, err404, err412, err422, err503, throwError)
import System.IO (stderr)

import En.Budget (EvaluationBudget)
import En.Check (CheckOutcome)
import En.Effect.ConsistencyStore (ConsistencyStore)
import En.Effect.TupleStore (RelationshipFilter, TupleStore)
import En.Error (EnError (..))
import En.Lookup qualified as Lookup
import En.LookupSubjects qualified as LookupSubjects
import En.Postgres.Database (Database)
import En.Reachability (ReachabilityGraph)
import En.Revision (Consistency)
import En.Schema (RelationName)
import En.Tuple (CaveatContext, ObjectRef, Subject)
import En.Watch qualified as Watch

type AppEffects = '[ConsistencyStore, TupleStore, Error EnError, Database, IOE]

{- | The authorization model a request is served under, and where it came from.

One value, read once per request, so the graph a handler evaluates against and the schema
hash the store interpreters mint and validate consistency tokens under always describe the
same model. A host that swaps this value between requests — @en-server@ does, on @SIGHUP@ —
gives in-flight requests the old model for free: a request holds its snapshot, and a swap
affects only later reads.

There is no @hash@ field: 'ReachabilityGraph' carries one, and a second copy could disagree
with it. Ask for @active.graph.hash@.

@source@ is the verbatim text the operator wrote, not a rendering of @graph@. @origin@ names
where it was read from — a file path, or @builtin-demo@ for the fallback model @en-server@
serves when @EN_SCHEMA_PATH@ is unset.
-}
data ActiveSchema = ActiveSchema
    { graph :: !ReachabilityGraph
    , source :: !Text
    , origin :: !Text
    , loadedAt :: !UTCTime
    }
    deriving stock (Eq, Show)

data Env es = Env
    { runPorts :: !(forall a. ActiveSchema -> Eff es a -> IO (Either EnError a))
    {- ^ Run an engine action under one schema snapshot. The snapshot is an argument rather
    than something the interpreters read for themselves because the store interpreters embed
    the schema hash in every token they mint and check it on every token they are shown: if a
    handler chose its graph and an interpreter chose its hash independently, a reload landing
    between the two would evaluate the old model and mint under the new one.
    -}
    , readActiveSchema :: !(IO ActiveSchema)
    {- ^ Take a snapshot. Called exactly once per request, at its start. A handler that called
    it twice could straddle a reload.
    -}
    , checkOperation :: !(ReachabilityGraph -> Consistency -> CaveatContext -> Subject -> RelationName -> ObjectRef -> Eff es CheckOutcome)
    , lookupWithDeadlineOperation :: !(Lookup.Deadline (Eff es) -> ReachabilityGraph -> Consistency -> Lookup.LookupRequest -> Eff es Lookup.LookupPage)
    , lookupSubjectsWithDeadlineOperation :: !(Lookup.Deadline (Eff es) -> ReachabilityGraph -> Consistency -> LookupSubjects.LookupSubjectsRequest -> Eff es LookupSubjects.LookupSubjectsPage)
    {- ^ Takes a 'Lookup.Deadline', not a deadline of its own: the two traversals poll the
    same kind of live clock, and one @deadlineMillis@ ceiling governs both.
    -}
    , watchOperation :: !(Watch.WatchStart -> Maybe RelationshipFilter -> Int -> Eff es Watch.WatchBatch)
    {- ^ One poll of the changelog feed. A field rather than a store call the handler makes
    itself — unlike the relationship read, which is a 'TupleStore' effect and nothing more —
    because the cursor codec is the datastore's, so only the host knows how to mint and
    validate one. A host that serves no feed supplies 'Watch.watchUnsupported'.
    -}
    , budget :: !EvaluationBudget
    {- ^ Static evaluation bounds. The operations above are already partially
    applied to this budget by whoever built the 'Env'; the field is carried so a
    host can report the bounds it runs under. It is engine configuration, never a
    per-request wire field: a client able to raise @maxDepth@ remotely holds an
    amplification lever.
    -}
    , maxBatchSize :: !Int
    , deadlineDefaultMillis :: !Int
    -- ^ Lookup budget when the client omits @deadlineMillis@.
    , deadlineMaxMillis :: !Int
    {- ^ Ceiling the server imposes on a client-supplied @deadlineMillis@. A larger
    request is clamped, not rejected: asking for "as long as you'll give me" is
    reasonable, and the server -- not the caller -- decides how long that is.
    -}
    }

type EnServer = Env AppEffects

{- | The single error shape of the en API.

@code@ is a stable machine-readable identifier; it is the contract, and never the
@Show@ output of an internal type. @retryable@ lets a client implement retry policy
without parsing prose: store outages are retryable, token and schema faults are not.
-}
data ErrorEnvelopeWire = ErrorEnvelopeWire
    { code :: !Text
    , message :: !Text
    , retryable :: !Bool
    }
    deriving stock (Eq, Show)

instance ToJSON ErrorEnvelopeWire where
    toJSON wire =
        Aeson.object ["code" .= wire.code, "message" .= wire.message, "retryable" .= wire.retryable]
    toEncoding wire =
        pairs ("code" .= wire.code <> "message" .= wire.message <> "retryable" .= wire.retryable)

instance FromJSON ErrorEnvelopeWire where
    parseJSON = withObject "ErrorEnvelopeWire" \o ->
        ErrorEnvelopeWire <$> o .: "code" <*> o .: "message" <*> o .: "retryable"

{- | A failure a handler can produce. The constructor selects the HTTP status, so the
'MultiVerb' response alternatives in "En.Servant.API" and the thrown 'ServerError's
used by embedded hosts are built from one source of truth.
-}
data EnFault
    = -- | 400: the caller sent something en cannot act on.
      BadRequestFault !ErrorEnvelopeWire
    | {- | 412: a write precondition did not hold, so the write was refused. The
      caller's request was well-formed; the world changed under it.
      -}
      PreconditionFailedFault !ErrorEnvelopeWire
    | -- | 422: the request was well-formed but exceeded an evaluation bound.
      UnprocessableFault !ErrorEnvelopeWire
    | -- | 503: a dependency of en failed. Retryable.
      UnavailableFault !ErrorEnvelopeWire
    deriving stock (Eq, Show)

{- | Map an engine error onto its status, stable code, and retryability.

'StoreError' deliberately drops its detail: it carries SQL text and bound parameters
(via @Hasql.toDetailedText@), which must not cross the trust boundary. 'logEnError'
prints it for the operator instead.
-}
enErrorToFault :: EnError -> EnFault
enErrorToFault = \case
    UnknownRelation relation ->
        BadRequestFault (envelope "unknown_relation" ("unknown relation or permission: " <> relation))
    SchemaViolation detail ->
        BadRequestFault (envelope "schema_violation" detail)
    MissingCaveatContext names ->
        BadRequestFault
            (envelope "missing_caveat_context" ("missing caveat context: " <> Text.intercalate ", " names))
    InvalidConsistencyToken detail ->
        BadRequestFault (envelope "invalid_consistency_token" detail)
    InvalidCursor cursor ->
        BadRequestFault (envelope "invalid_cursor" ("malformed pagination cursor: " <> cursor))
    ResolutionLimitExceeded ->
        UnprocessableFault
            (envelope "resolution_limit_exceeded" "the traversal exceeded its depth or breadth bound")
    CycleDetected subproblem ->
        UnprocessableFault
            (envelope "cycle_detected" ("the relationship data contains a cycle at " <> subproblem))
    WritePreconditionFailed description ->
        PreconditionFailedFault
            (envelope "write_precondition_failed" ("write precondition did not hold: " <> description))
    StoreError _detail ->
        UnavailableFault
            ErrorEnvelopeWire
                { code = "store_error"
                , message = "the tuple store failed; retry later"
                , retryable = True
                }
  where
    envelope code message = ErrorEnvelopeWire{code, message, retryable = False}

-- | A 400 under an arbitrary stable code. No client fault is ever retryable.
badRequest :: Text -> Text -> EnFault
badRequest code message =
    BadRequestFault ErrorEnvelopeWire{code, message, retryable = False}

-- | A request en rejected before it reached the engine.
invalidRequest :: Text -> EnFault
invalidRequest = badRequest "invalid_request"

-- | A batch larger than the configured maximum.
batchTooLarge :: Text -> EnFault
batchTooLarge = badRequest "batch_too_large"

{- | A 404 for a path that matches no route. Not an 'EnFault': Servant raises it
before any handler runs, so no operation can return it.
-}
notFound :: ServerError
notFound =
    envelopeError err404 ErrorEnvelopeWire{code = "not_found", message = "no such endpoint", retryable = False}

{- | A 403 for embedded host routes gated by 'En.Servant.Authorize.requirePermission'.
Not an 'EnFault': no @EnAPI@ operation can produce it, so it has no response
alternative to return into.
-}
permissionDenied :: Text -> ServerError
permissionDenied message =
    envelopeError err403 ErrorEnvelopeWire{code = "permission_denied", message, retryable = False}

-- | Render a fault as the 'ServerError' that carries it at the status it names.
faultToServerError :: EnFault -> ServerError
faultToServerError = \case
    BadRequestFault envelope -> envelopeError err400 envelope
    PreconditionFailedFault envelope -> envelopeError err412 envelope
    UnprocessableFault envelope -> envelopeError err422 envelope
    UnavailableFault envelope -> envelopeError err503 envelope

-- | Attach an envelope to a 'ServerError', at that error's status.
envelopeError :: ServerError -> ErrorEnvelopeWire -> ServerError
envelopeError err envelope =
    err
        { errBody = encode envelope
        , errHeaders = [("Content-Type", Text.encodeUtf8 "application/json")]
        }

{- | The detail an operator needs and a caller must not see.

Only 'StoreError' carries such detail today. EP-36's structured logging formalizes
this; until then, stderr.
-}
logEnError :: EnError -> IO ()
logEnError = \case
    StoreError detail -> Text.hPutStrLn stderr ("en: store error: " <> detail)
    _ -> pure ()

{- | Run an engine action under a snapshot, throwing on failure.

For embedded host routes, which have no response alternative to return a fault into.
@EnAPI@'s own handlers use 'runEngineEither'.
-}
runEngine :: Env es -> ActiveSchema -> Eff es a -> Handler a
runEngine env active action = do
    result <- runEngineEither env active action
    either (throwError . faultToServerError) pure result

-- | Run an engine action under a snapshot, returning its failure as a value.
runEngineEither :: Env es -> ActiveSchema -> Eff es a -> Handler (Either EnFault a)
runEngineEither Env{runPorts} active action = do
    result <- liftIO (runPorts active action)
    case result of
        Right value -> pure (Right value)
        Left err -> do
            liftIO (logEnError err)
            pure (Left (enErrorToFault err))

{- | The engine-error mapping as a 'ServerError', for embedded hosts that catch it.

Note this does /not/ log: 'runEngine' has already done so on the path that matters.
-}
enErrorToServerError :: EnError -> ServerError
enErrorToServerError =
    faultToServerError . enErrorToFault
