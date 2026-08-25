{-# LANGUAGE RankNTypes #-}

-- | The seam between en's effectful engine stack and servant's 'Handler'.
module En.Servant.Seam
  ( AppEffects,
    ActiveSchema (..),
    Env (..),
    MintEnv (..),
    EnServer,
    EnFault (..),
    enErrorToFault,
    badRequest,
    invalidRequest,
    batchTooLarge,
    permissionDenied,
    notFound,
    faultToServerError,
    runEngine,
    runEngineEither,
    enErrorToServerError,
  )
where

import Auth.Biscuit (SecretKey)
import Control.Monad.IO.Class (liftIO)
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Text.IO qualified as Text
import Data.Time (NominalDiffTime, UTCTime)
import Effectful (Eff, IOE)
import Effectful.Error.Static (Error)
import En.Biscuit.Keys (IssuerKeyId)
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
import En.Servant.Problem
  ( ProblemDetails,
    ProblemSpec,
    problem,
    problemError,
    specBatchTooLarge,
    specConsistencyTokenExpired,
    specCycleDetected,
    specInternalError,
    specInvalidConsistencyToken,
    specInvalidCursor,
    specInvalidRequest,
    specMalformedConsistencyToken,
    specMissingCaveatContext,
    specNotFound,
    specPermissionDenied,
    specResolutionLimitExceeded,
    specSchemaViolation,
    specStoreError,
    specUnknownRelation,
    specWritePreconditionFailed,
  )
import En.Tuple (CaveatContext, ObjectRef, Subject)
import En.Watch qualified as Watch
import Servant (Handler, ServerError (..), err400, err403, err404, err412, err422, err500, err503, throwError)
import System.IO (stderr)

type AppEffects = '[ConsistencyStore, TupleStore, Error EnError, Database, IOE]

-- | The authorization model a request is served under, and where it came from.
--
-- One value, read once per request, so the graph a handler evaluates against and the schema
-- hash the store interpreters mint and validate consistency tokens under always describe the
-- same model. A host that swaps this value between requests — @en-server@ does, on @SIGHUP@ —
-- gives in-flight requests the old model for free: a request holds its snapshot, and a swap
-- affects only later reads.
--
-- There is no @hash@ field: 'ReachabilityGraph' carries one, and a second copy could disagree
-- with it. Ask for @active.graph.hash@.
--
-- @source@ is the verbatim text the operator wrote, not a rendering of @graph@. @origin@ names
-- where it was read from — a file path, or @builtin-demo@ for the fallback model @en-server@
-- serves when @EN_SCHEMA_PATH@ is unset.
data ActiveSchema = ActiveSchema
  { graph :: !ReachabilityGraph,
    source :: !Text,
    origin :: !Text,
    loadedAt :: !UTCTime
  }
  deriving stock (Eq, Show)

data Env es = Env
  { -- | Run an engine action under one schema snapshot. The snapshot is an argument rather
    --     than something the interpreters read for themselves because the store interpreters embed
    --     the schema hash in every token they mint and check it on every token they are shown: if a
    --     handler chose its graph and an interpreter chose its hash independently, a reload landing
    --     between the two would evaluate the old model and mint under the new one.
    runPorts :: !(forall a. ActiveSchema -> Eff es a -> IO (Either EnError a)),
    -- | Take a snapshot. Called exactly once per request, at its start. A handler that called
    --     it twice could straddle a reload.
    readActiveSchema :: !(IO ActiveSchema),
    checkOperation :: !(ReachabilityGraph -> Consistency -> CaveatContext -> Subject -> RelationName -> ObjectRef -> Eff es CheckOutcome),
    lookupWithDeadlineOperation :: !(Lookup.Deadline (Eff es) -> ReachabilityGraph -> Consistency -> Lookup.LookupRequest -> Eff es Lookup.LookupPage),
    -- | Takes a 'Lookup.Deadline', not a deadline of its own: the two traversals poll the
    --     same kind of live clock, and one @deadlineMillis@ ceiling governs both.
    lookupSubjectsWithDeadlineOperation :: !(Lookup.Deadline (Eff es) -> ReachabilityGraph -> Consistency -> LookupSubjects.LookupSubjectsRequest -> Eff es LookupSubjects.LookupSubjectsPage),
    -- | One poll of the changelog feed. A field rather than a store call the handler makes
    --     itself — unlike the relationship read, which is a 'TupleStore' effect and nothing more —
    --     because the cursor codec is the datastore's, so only the host knows how to mint and
    --     validate one. A host that serves no feed supplies 'Watch.watchUnsupported'.
    watchOperation :: !(Watch.WatchStart -> Maybe RelationshipFilter -> Int -> Eff es Watch.WatchBatch),
    -- | Static evaluation bounds. The operations above are already partially
    --     applied to this budget by whoever built the 'Env'; the field is carried so a
    --     host can report the bounds it runs under. It is engine configuration, never a
    --     per-request wire field: a client able to raise @maxDepth@ remotely holds an
    --     amplification lever.
    budget :: !EvaluationBudget,
    maxBatchSize :: !Int,
    -- | Lookup budget when the client omits @deadlineMillis@.
    deadlineDefaultMillis :: !Int,
    -- | Ceiling the server imposes on a client-supplied @deadlineMillis@. A larger
    --     request is clamped, not rejected: asking for "as long as you'll give me" is
    --     reasonable, and the server -- not the caller -- decides how long that is.
    deadlineMaxMillis :: !Int,
    -- | Issuer configuration for @POST \/v1\/grants@. 'Nothing' disables the
    --     endpoint: the handler answers 404, so a server that configures no issuer key
    --     does not advertise a minting capability it cannot fulfil. A host that wants
    --     HTTP grant minting supplies 'Just'; see @docs/plans/57-mint-biscuit-grants-over-http.md@.
    mint :: !(Maybe MintEnv)
  }

-- | What @POST \/v1\/grants@ needs to mint a decision token: the issuer key
-- material and the token-lifetime bounds. Deliberately /not/ the active schema
-- hash — the handler reads that from the request-time 'ActiveSchema' snapshot
-- (@active.graph.hash@), the same snapshot its check evaluated against, so a
-- @SIGHUP@ schema reload can never mint a grant claiming a hash the check did not
-- evaluate under.
data MintEnv = MintEnv
  { -- | The Biscuit issuer's private signing key. Never logged.
    issuerSecretKey :: !SecretKey,
    -- | The id of 'issuerSecretKey', stamped into every minted token's envelope
    --     so verifiers select the matching public key from their keyset (EP-55).
    issuerKeyId :: !IssuerKeyId,
    -- | Token lifetime when the request omits @ttlSeconds@.
    defaultTtl :: !NominalDiffTime,
    -- | Upper bound on a caller-requested @ttlSeconds@. A request above it is
    --     rejected with 400 rather than clamped, so a caller never caches a token with
    --     a lifetime different from the one it asked for.
    maxTtl :: !NominalDiffTime
  }

type EnServer = Env AppEffects

-- | A failure a handler can produce. The constructor selects the HTTP status, so the
-- 'MultiVerb' response alternatives in "En.Servant.API" and the thrown 'ServerError's
-- used by embedded hosts are built from one source of truth.
data EnFault
  = -- | 400: the caller sent something en cannot act on.
    BadRequestFault !ProblemDetails
  | -- | 412: a write precondition did not hold, so the write was refused. The
    --       caller's request was well-formed; the world changed under it.
    PreconditionFailedFault !ProblemDetails
  | -- | 422: the request was well-formed but exceeded an evaluation bound.
    UnprocessableFault !ProblemDetails
  | -- | 500: en itself failed. Retrying the same request cannot help.
    InternalFault !ProblemDetails
  | -- | 503: a dependency of en failed. Retryable.
    UnavailableFault !ProblemDetails
  deriving stock (Eq, Show)

-- | Map an engine error onto its status, stable code, and retryability.
--
-- 'StoreError' deliberately drops its detail: it carries SQL text and bound parameters
-- (via @Hasql.toDetailedText@), which must not cross the trust boundary. 'logEnError'
-- prints it for the operator instead.
enErrorToFault :: EnError -> EnFault
enErrorToFault = \case
  UnknownRelation relation ->
    BadRequestFault (problem specUnknownRelation ("unknown relation or permission: " <> relation))
  SchemaViolation detail ->
    BadRequestFault (problem specSchemaViolation detail)
  MissingCaveatContext names ->
    BadRequestFault
      (problem specMissingCaveatContext ("missing caveat context: " <> Text.intercalate ", " names))
  MalformedConsistencyToken detail ->
    BadRequestFault (problem specMalformedConsistencyToken detail)
  ConsistencyTokenExpired detail ->
    BadRequestFault (problem specConsistencyTokenExpired detail)
  InvalidConsistencyToken detail ->
    BadRequestFault (problem specInvalidConsistencyToken detail)
  InvalidCursor cursor ->
    BadRequestFault (problem specInvalidCursor ("malformed pagination cursor: " <> cursor))
  ResolutionLimitExceeded ->
    UnprocessableFault
      (problem specResolutionLimitExceeded "the traversal exceeded its depth or breadth bound")
  CycleDetected subproblem ->
    UnprocessableFault
      (problem specCycleDetected ("the relationship data contains a cycle at " <> subproblem))
  WritePreconditionFailed description ->
    PreconditionFailedFault
      (problem specWritePreconditionFailed ("write precondition did not hold: " <> description))
  InternalError _detail ->
    InternalFault (problem specInternalError "en failed to process the request")
  StoreError _detail ->
    UnavailableFault (problem specStoreError "the tuple store failed; retry later")

-- | A 400 under an arbitrary stable code. No client fault is ever retryable.
badRequest :: ProblemSpec -> Text -> EnFault
badRequest spec message =
  BadRequestFault (problem spec message)

-- | A request en rejected before it reached the engine.
invalidRequest :: Text -> EnFault
invalidRequest = badRequest specInvalidRequest

-- | A batch larger than the configured maximum.
batchTooLarge :: Text -> EnFault
batchTooLarge = badRequest specBatchTooLarge

-- | A 404 for a path that matches no route. Not an 'EnFault': Servant raises it
-- before any handler runs, so no operation can return it.
notFound :: ServerError
notFound =
  problemError err404 (problem specNotFound "no such endpoint")

-- | A 403 for embedded host routes gated by 'En.Servant.Authorize.requirePermission'.
-- Not an 'EnFault': no @EnAPI@ operation can produce it, so it has no response
-- alternative to return into.
permissionDenied :: Text -> ServerError
permissionDenied message =
  problemError err403 (problem specPermissionDenied message)

-- | Render a fault as the 'ServerError' that carries it at the status it names.
faultToServerError :: EnFault -> ServerError
faultToServerError = \case
  BadRequestFault details -> problemError err400 details
  PreconditionFailedFault details -> problemError err412 details
  UnprocessableFault details -> problemError err422 details
  InternalFault details -> problemError err500 details
  UnavailableFault details -> problemError err503 details

-- | The detail an operator needs and a caller must not see.
--
-- Store and internal errors carry operator-only detail. EP-36's structured logging
-- formalizes this; until then, stderr.
logEnError :: EnError -> IO ()
logEnError = \case
  StoreError detail -> Text.hPutStrLn stderr ("en: store error: " <> detail)
  InternalError detail -> Text.hPutStrLn stderr ("en: internal error: " <> detail)
  _ -> pure ()

-- | Run an engine action under a snapshot, throwing on failure.
--
-- For embedded host routes, which have no response alternative to return a fault into.
-- @EnAPI@'s own handlers use 'runEngineEither'.
runEngine :: Env es -> ActiveSchema -> Eff es a -> Handler a
runEngine env active action = do
  result <- runEngineEither env active action
  either (throwError . faultToServerError) pure result

-- | Run an engine action under a snapshot, returning its failure as a value.
runEngineEither :: Env es -> ActiveSchema -> Eff es a -> Handler (Either EnFault a)
runEngineEither Env {runPorts} active action = do
  result <- liftIO (runPorts active action)
  case result of
    Right value -> pure (Right value)
    Left err -> do
      liftIO (logEnError err)
      pure (Left (enErrorToFault err))

-- | The engine-error mapping as a 'ServerError', for embedded hosts that catch it.
--
-- Note this does /not/ log: 'runEngine' has already done so on the path that matters.
enErrorToServerError :: EnError -> ServerError
enErrorToServerError =
  faultToServerError . enErrorToFault
