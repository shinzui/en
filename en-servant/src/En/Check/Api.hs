{-# LANGUAGE TypeOperators #-}

{- | The check HTTP slice: the single check, the batch check, and grant minting. The mint
is a check-then-issue — it runs its own check and mints a Biscuit only on 'Allowed' — so
it reuses the check flow and lives beside it. The @\/v1@ prefix is factored to the
umbrella in "En.Servant.API".
-}
module En.Check.Api (
    -- * Routes
    CheckRoutes (..),
    checkRoutesServer,

    -- * Wire types
    CheckRequestWire (..),
    CheckResponseWire (..),
    BatchCheckPairWire (..),
    BatchCheckRequestWire (..),
    BatchCheckResponseWire (..),
    MintGrantRequestWire (..),
    MintGrantResponseWire (..),

    -- * Handlers
    checkHandler,
    batchCheckHandler,
    mintGrantHandler,
) where

import Control.Monad.IO.Class (liftIO)
import Control.Monad.Trans.Except (throwE)
import Data.Aeson (
    FromJSON (..),
    ToJSON (..),
    pairs,
    withObject,
    (.:),
    (.:?),
    (.=),
 )
import Data.Aeson qualified as Aeson
import Data.List.NonEmpty qualified as NonEmpty
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Text.Encoding (decodeUtf8)
import Data.Time (NominalDiffTime, UTCTime, addUTCTime, getCurrentTime)
import Effectful qualified
import GHC.Generics (Generic)
import Servant (
    Handler,
    JSON,
    Post,
    ReqBody,
    ServerError,
    StdMethod (..),
    err403,
    err404,
    throwError,
    type (:>),
 )
import Servant.API.Generic (type (:-))
import Servant.API.MultiVerb (MultiVerb)
import Servant.Server.Generic (AsServerT)

import Auth.Biscuit.Utils (encodeHex)
import En.Biscuit.Grant (Audience (..), EnGrant (..), RequestId (..))
import En.Biscuit.Mint (MintConfig (..), MintedGrant (..), mintObjectGrantWithExpiry)
import En.Check (BatchOutcome (..), BatchPair (..), CheckDecision (..), CheckOutcome (..), checkMany)
import En.Effect.ConsistencyStore (ConsistencyStore)
import En.Effect.TupleStore (TupleStore)
import En.Revision (Consistency, ConsistencyToken (..))

-- 'ReachabilityGraph' is imported for its @hash@ field, not its constructor: GHC solves the
-- @HasField "hash"@ constraint behind @active.graph.hash@ only when the field is in scope.
import En.Reachability (ReachabilityGraph (..))
import En.Schema (RelationName (..))
import En.Servant.Response (
    EnResponses,
    EnResult,
    activeSchema,
    enHandler,
    engine,
    orInvalid,
    traverseOrInvalid,
 )
import En.Servant.Seam (
    ActiveSchema (..),
    EnFault,
    Env (..),
    ErrorEnvelopeWire (..),
    MintEnv (..),
    badRequest,
    batchTooLarge,
    envelopeError,
    faultToServerError,
    invalidRequest,
    runEngineEither,
 )
import En.Servant.Wire (
    CaveatContextWire,
    CheckDecisionWire (..),
    ConsistencyWire,
    ObjectRefWire,
    SubjectWire,
    consistencyFromWire,
    contextFromWire,
    decisionToWire,
    nonEmptyRelation,
    objectRefFromWire,
    subjectFromWire,
 )
import En.Tuple (CaveatContext, ObjectRef, Subject (..))

-- * Routes

data CheckRoutes mode = CheckRoutes
    { check ::
        mode
            :- "check"
                :> ReqBody '[JSON] CheckRequestWire
                :> MultiVerb 'POST '[JSON] (EnResponses "The authorization decision" CheckResponseWire) (EnResult CheckResponseWire)
    , batchCheck ::
        mode
            :- "batch-check"
                :> ReqBody '[JSON] BatchCheckRequestWire
                :> MultiVerb 'POST '[JSON] (EnResponses "One decision per requested pair, in order" BatchCheckResponseWire) (EnResult BatchCheckResponseWire)
    , mintGrant ::
        mode
            :- "grants"
                :> ReqBody '[JSON] MintGrantRequestWire
                :> Post '[JSON] MintGrantResponseWire
    }
    deriving stock (Generic)

checkRoutesServer ::
    (ConsistencyStore Effectful.:> es, TupleStore Effectful.:> es) =>
    Env es ->
    CheckRoutes (AsServerT Handler)
checkRoutesServer env =
    CheckRoutes
        { check = checkHandler env
        , batchCheck = batchCheckHandler env
        , mintGrant = mintGrantHandler env
        }

-- * Wire types

data CheckRequestWire = CheckRequestWire
    { consistency :: !ConsistencyWire
    , context :: !CaveatContextWire
    , subject :: !SubjectWire
    , permission :: !Text
    , object :: !ObjectRefWire
    }
    deriving stock (Eq, Show)

instance ToJSON CheckRequestWire where
    toJSON wire =
        Aeson.object
            [ "consistency" .= wire.consistency
            , "context" .= wire.context
            , "subject" .= wire.subject
            , "permission" .= wire.permission
            , "object" .= wire.object
            ]
    toEncoding wire =
        pairs
            ( "consistency" .= wire.consistency
                <> "context" .= wire.context
                <> "subject" .= wire.subject
                <> "permission" .= wire.permission
                <> "object" .= wire.object
            )

instance FromJSON CheckRequestWire where
    parseJSON = withObject "CheckRequestWire" \o ->
        CheckRequestWire
            <$> o .: "consistency"
            <*> o .: "context"
            <*> o .: "subject"
            <*> o .: "permission"
            <*> o .: "object"

{- | A decision, and the consistency token naming the snapshot it was decided at.

@checkedAt@ is what makes a read chainable: send it back as
@{"consistency": {"requirement": "atLeastAsFresh", "token": …}}@ on a follow-up
read and that read is guaranteed to observe everything this one observed.
-}
data CheckResponseWire = CheckResponseWire
    { decision :: !CheckDecisionWire
    , checkedAt :: !Text
    }
    deriving stock (Eq, Show)

instance ToJSON CheckResponseWire where
    toJSON wire = Aeson.object ["decision" .= wire.decision, "checkedAt" .= wire.checkedAt]
    toEncoding wire = pairs ("decision" .= wire.decision <> "checkedAt" .= wire.checkedAt)

instance FromJSON CheckResponseWire where
    parseJSON = withObject "CheckResponseWire" \o ->
        CheckResponseWire <$> o .: "decision" <*> o .: "checkedAt"

data BatchCheckPairWire = BatchCheckPairWire
    { subject :: !SubjectWire
    , permission :: !Text
    , object :: !ObjectRefWire
    }
    deriving stock (Eq, Show)

instance ToJSON BatchCheckPairWire where
    toJSON wire =
        Aeson.object ["subject" .= wire.subject, "permission" .= wire.permission, "object" .= wire.object]
    toEncoding wire =
        pairs ("subject" .= wire.subject <> "permission" .= wire.permission <> "object" .= wire.object)

instance FromJSON BatchCheckPairWire where
    parseJSON = withObject "BatchCheckPairWire" \o ->
        BatchCheckPairWire <$> o .: "subject" <*> o .: "permission" <*> o .: "object"

data BatchCheckRequestWire = BatchCheckRequestWire
    { consistency :: !ConsistencyWire
    , context :: !CaveatContextWire
    , pairs :: ![BatchCheckPairWire]
    }
    deriving stock (Eq, Show)

instance ToJSON BatchCheckRequestWire where
    toJSON wire =
        Aeson.object
            [ "consistency" .= wire.consistency
            , "context" .= wire.context
            , "pairs" .= wire.pairs
            ]
    toEncoding wire =
        pairs
            ( "consistency" .= wire.consistency
                <> "context" .= wire.context
                <> "pairs" .= wire.pairs
            )

instance FromJSON BatchCheckRequestWire where
    parseJSON = withObject "BatchCheckRequestWire" \o ->
        BatchCheckRequestWire <$> o .: "consistency" <*> o .: "context" <*> o .: "pairs"

{- | Decisions in input order, and the one snapshot the whole batch was decided at.

One @checkedAt@, not one per pair: the engine resolves consistency once and
evaluates every pair against that revision, so per-pair tokens would be copies.
-}
data BatchCheckResponseWire = BatchCheckResponseWire
    { decisions :: ![CheckDecisionWire]
    , checkedAt :: !Text
    }
    deriving stock (Eq, Show)

instance ToJSON BatchCheckResponseWire where
    toJSON wire = Aeson.object ["decisions" .= wire.decisions, "checkedAt" .= wire.checkedAt]
    toEncoding wire = pairs ("decisions" .= wire.decisions <> "checkedAt" .= wire.checkedAt)

instance FromJSON BatchCheckResponseWire where
    parseJSON = withObject "BatchCheckResponseWire" \o ->
        BatchCheckResponseWire <$> o .: "decisions" <*> o .: "checkedAt"

{- | A request to mint a decision token for one subject/permission/object.

The server runs its own @check@ at @consistency@ (it never trusts a
caller-asserted decision), and mints only if that check is @Allowed@. @subject@
must be a concrete @id@ subject — a userset or wildcard cannot be encoded into a
grant and is rejected with 400. @audience@ names the downstream service the token
is for; a verifier rejects a token whose audience is not its own. @ttlSeconds@,
if given, must be positive and no greater than the server's configured maximum
(else 400); omitted, the server's default TTL applies. @requestId@ is an optional
correlation id echoed into the token's @en_request_id@ fact.
-}
data MintGrantRequestWire = MintGrantRequestWire
    { consistency :: !ConsistencyWire
    , context :: !CaveatContextWire
    , subject :: !SubjectWire
    , permission :: !Text
    , object :: !ObjectRefWire
    , audience :: !Text
    , ttlSeconds :: !(Maybe Int)
    , requestId :: !(Maybe Text)
    }
    deriving stock (Eq, Show)

instance ToJSON MintGrantRequestWire where
    toJSON wire =
        Aeson.object $
            [ "consistency" .= wire.consistency
            , "context" .= wire.context
            , "subject" .= wire.subject
            , "permission" .= wire.permission
            , "object" .= wire.object
            , "audience" .= wire.audience
            ]
                <> foldMap (\value -> ["ttlSeconds" .= value]) wire.ttlSeconds
                <> foldMap (\value -> ["requestId" .= value]) wire.requestId
    toEncoding wire =
        pairs $
            "consistency" .= wire.consistency
                <> "context" .= wire.context
                <> "subject" .= wire.subject
                <> "permission" .= wire.permission
                <> "object" .= wire.object
                <> "audience" .= wire.audience
                <> foldMap ("ttlSeconds" .=) wire.ttlSeconds
                <> foldMap ("requestId" .=) wire.requestId

instance FromJSON MintGrantRequestWire where
    parseJSON = withObject "MintGrantRequestWire" \o ->
        MintGrantRequestWire
            <$> o .: "consistency"
            <*> o .: "context"
            <*> o .: "subject"
            <*> o .: "permission"
            <*> o .: "object"
            <*> o .: "audience"
            <*> o .:? "ttlSeconds"
            <*> o .:? "requestId"

{- | A freshly minted decision token and its metadata.

@token@ is the URL-safe base64 Biscuit the caller forwards downstream in the
@X-En-Biscuit@ header. @expiresAt@ is the absolute expiry stamped into it.
@revocationIds@ are the token's built-in block revocation ids, hex-encoded; an
issuer records them if it might revoke the token before expiry. @checkedAt@ is
the consistency token the mint's check evaluated at, and is the same value signed
into the grant as its @en_consistency_token@ — a downstream that wants a read no
staler than the decision sends it back as @atLeastAsFresh@.
-}
data MintGrantResponseWire = MintGrantResponseWire
    { token :: !Text
    , expiresAt :: !UTCTime
    , revocationIds :: ![Text]
    , checkedAt :: !Text
    }
    deriving stock (Eq, Show)

instance ToJSON MintGrantResponseWire where
    toJSON wire =
        Aeson.object
            [ "token" .= wire.token
            , "expiresAt" .= wire.expiresAt
            , "revocationIds" .= wire.revocationIds
            , "checkedAt" .= wire.checkedAt
            ]
    toEncoding wire =
        pairs
            ( "token" .= wire.token
                <> "expiresAt" .= wire.expiresAt
                <> "revocationIds" .= wire.revocationIds
                <> "checkedAt" .= wire.checkedAt
            )

instance FromJSON MintGrantResponseWire where
    parseJSON = withObject "MintGrantResponseWire" \o ->
        MintGrantResponseWire
            <$> o .: "token"
            <*> o .: "expiresAt"
            <*> o .: "revocationIds"
            <*> o .: "checkedAt"

-- * Handlers

checkHandler :: Env es -> CheckRequestWire -> Handler (EnResult CheckResponseWire)
checkHandler env request = enHandler do
    active <- activeSchema env
    consistency <- orInvalid (consistencyFromWire request.consistency)
    context <- orInvalid (contextFromWire request.context)
    subject <- orInvalid (subjectFromWire request.subject)
    object <- orInvalid (objectRefFromWire request.object)
    outcome <-
        engine
            env
            active
            ( env.checkOperation
                active.graph
                consistency
                context
                subject
                (RelationName request.permission)
                object
            )
    let ConsistencyToken checkedAt = outcome.checkedAt
    pure CheckResponseWire{decision = decisionToWire outcome.decision, checkedAt}

batchCheckHandler :: (ConsistencyStore Effectful.:> es, TupleStore Effectful.:> es) => Env es -> BatchCheckRequestWire -> Handler (EnResult BatchCheckResponseWire)
batchCheckHandler env request = enHandler do
    active <- activeSchema env
    if length request.pairs > env.maxBatchSize
        then
            throwE
                (batchTooLarge ("batch exceeds the maximum of " <> Text.pack (show env.maxBatchSize) <> " pairs"))
        else pure ()
    consistency <- orInvalid (consistencyFromWire request.consistency)
    context <- orInvalid (contextFromWire request.context)
    batchPairs <- traverseOrInvalid pairFromWire request.pairs
    outcome <-
        engine
            env
            active
            ( checkMany
                active.graph
                consistency
                context
                batchPairs
            )
    let ConsistencyToken checkedAt = outcome.checkedAt
    -- Fail closed on the wire: a pair the engine could not evaluate is reported
    -- as a denial. The engine now preserves the error, so
    -- docs/plans/35-version-the-wire-contract-and-type-the-error-model.md can
    -- add a per-pair error channel without touching evaluation.
    pure
        BatchCheckResponseWire
            { decisions = either (const DeniedWire) decisionToWire <$> outcome.decisions
            , checkedAt
            }
  where
    pairFromWire :: BatchCheckPairWire -> Either Text BatchPair
    pairFromWire wire =
        BatchPair
            <$> subjectFromWire wire.subject
            <*> ( if Text.null wire.permission
                    then Left "permission must not be empty"
                    else Right (RelationName wire.permission)
                )
            <*> objectRefFromWire wire.object

{- | The decoded, validated inputs a mint needs, projected out of
'MintGrantRequestWire' once so the handler proper reads as the check-then-mint
flow it is.
-}
data MintInputs = MintInputs
    { consistency :: !Consistency
    , context :: !CaveatContext
    , subject :: !Subject
    , permission :: !RelationName
    , object :: !ObjectRef
    , audience :: !Text
    , ttl :: !NominalDiffTime
    , requestId :: !(Maybe Text)
    }

{- | Mint a Biscuit decision token for one subject/permission/object, if an
authenticated caller's request is 'Allowed'.

Unlike every other en operation this throws its failures as
'Servant.ServerError's rather than returning an 'EnResult': its status set — 404
when minting is disabled, 403 when the decision is not 'Allowed', 400 on a bad
request — is not the shared 'EnResponses'. Each thrown error still carries the
'ErrorEnvelopeWire' envelope with a stable @code@.

The flow is check-then-mint-at-that-token, and it never trusts a caller-asserted
decision: it runs its own check through 'Env.checkOperation' and mints only on
'Allowed', binding the grant to the consistency token that check evaluated at
('CheckOutcome.checkedAt') and to the hash of the very schema snapshot the check
ran against (@active.graph.hash@). 'mintObjectGrantWithExpiry' enforces the
'Allowed'-only rule again, independently.
-}
mintGrantHandler :: Env es -> MintGrantRequestWire -> Handler MintGrantResponseWire
mintGrantHandler env request =
    case env.mint of
        Nothing -> throwError mintingDisabled
        Just mintEnv -> do
            inputs <- either (throwError . faultToServerError) pure (decodeMintRequest mintEnv request)
            active <- liftIO env.readActiveSchema
            outcome <-
                runEngineEither env active $
                    env.checkOperation
                        active.graph
                        inputs.consistency
                        inputs.context
                        inputs.subject
                        inputs.permission
                        inputs.object
            CheckOutcome{decision, checkedAt} <- either (throwError . faultToServerError) pure outcome
            case decision of
                Denied -> throwError (decisionNotAllowed "the authorization decision was Denied")
                Conditional _ -> throwError (decisionNotAllowed "the authorization decision was Conditional")
                Allowed -> do
                    mintedAt <- liftIO getCurrentTime
                    let expiry = addUTCTime inputs.ttl mintedAt
                        grant =
                            EnGrant
                                { subject = inputs.subject
                                , permission = inputs.permission
                                , object = inputs.object
                                , consistencyToken = checkedAt
                                , schemaHash = active.graph.hash
                                , expiresAt = expiry
                                , audience = Audience inputs.audience
                                , requestId = RequestId <$> inputs.requestId
                                , revocationId = Nothing
                                }
                        config =
                            MintConfig
                                { issuerSecretKey = mintEnv.issuerSecretKey
                                , issuerKeyId = mintEnv.issuerKeyId
                                , defaultTtl = mintEnv.defaultTtl
                                , now = pure mintedAt
                                }
                    minted <- mintObjectGrantWithExpiry config expiry decision grant
                    case minted of
                        Left mintErr ->
                            throwError (faultToServerError (badRequest "grant_not_mintable" (Text.pack (show mintErr))))
                        Right MintedGrant{token, expiresAt, revocationIds} ->
                            let ConsistencyToken checkedAtText = checkedAt
                             in pure
                                    MintGrantResponseWire
                                        { token = decodeUtf8 token
                                        , expiresAt
                                        , revocationIds = encodeHex <$> NonEmpty.toList revocationIds
                                        , checkedAt = checkedAtText
                                        }

-- | 404 for @POST \/v1\/grants@ on a server that configured no issuer key.
mintingDisabled :: ServerError
mintingDisabled =
    envelopeError
        err404
        ErrorEnvelopeWire{code = "not_found", message = "grant minting is not enabled", retryable = False}

-- | 403 for a mint whose check was 'Denied' or 'Conditional'. Never retryable.
decisionNotAllowed :: Text -> ServerError
decisionNotAllowed message =
    envelopeError err403 ErrorEnvelopeWire{code = "decision_not_allowed", message, retryable = False}

{- | Decode and validate a mint request, or a 400 'EnFault' naming the fault.

A non-concrete subject and a @ttlSeconds@ above the configured maximum are
rejected here rather than deep in the mint: @grantBlock@ would fail closed on the
subject anyway, but a 400 is a clearer contract than the 500 an unencodable grant
would otherwise become.
-}
decodeMintRequest :: MintEnv -> MintGrantRequestWire -> Either EnFault MintInputs
decodeMintRequest mintEnv request = do
    consistency <- orFault (consistencyFromWire request.consistency)
    context <- orFault (contextFromWire request.context)
    subject <- orFault (concreteSubjectFromWire request.subject)
    object <- orFault (objectRefFromWire request.object)
    permission <- orFault (nonEmptyRelation "permission" request.permission)
    audience <- orFault (nonEmptyText "audience" request.audience)
    ttl <- orFault (resolveTtl mintEnv request.ttlSeconds)
    pure
        MintInputs
            { consistency
            , context
            , subject
            , permission
            , object
            , audience
            , ttl
            , requestId = request.requestId
            }
  where
    orFault :: Either Text a -> Either EnFault a
    orFault = either (Left . invalidRequest) Right

{- | A grant needs a concrete @id@ subject: a userset or wildcard cannot be
encoded into the grant vocabulary. Reject it as a client fault.
-}
concreteSubjectFromWire :: SubjectWire -> Either Text Subject
concreteSubjectFromWire wire = do
    subject <- subjectFromWire wire
    case subject of
        SubjectId _ -> Right subject
        _ -> Left "grants require a concrete subject (kind \"id\")"

{- | The token lifetime for a mint: the request's @ttlSeconds@ if given, else the
server default. A requested TTL must be positive and no greater than the server
maximum — a request above the maximum is rejected, not silently clamped, so a
caller never caches a token with a lifetime different from the one it asked for.
-}
resolveTtl :: MintEnv -> Maybe Int -> Either Text NominalDiffTime
resolveTtl mintEnv = \case
    Nothing -> Right mintEnv.defaultTtl
    Just seconds
        | seconds <= 0 -> Left "ttlSeconds must be positive"
        | fromIntegral seconds > mintEnv.maxTtl ->
            Left
                ( "ttlSeconds exceeds the configured maximum of "
                    <> Text.pack (show (round mintEnv.maxTtl :: Integer))
                    <> " seconds"
                )
        | otherwise -> Right (fromIntegral seconds)

nonEmptyText :: Text -> Text -> Either Text Text
nonEmptyText label value
    | Text.null value = Left (label <> " must not be empty")
    | otherwise = Right value
