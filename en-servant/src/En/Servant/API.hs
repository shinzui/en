{-# LANGUAGE TypeOperators #-}

-- | The en HTTP API as a Servant API type plus server handlers.
module En.Servant.API (
    EnAPI,
    apiProxy,
    EnServer,
    Env (..),
    server,
    app,
    EnResponses,
    EnResult (..),
    ObjectRefWire (..),
    SubjectWire (..),
    TupleWire (..),
    TupleCaveatWire (..),
    CaveatValueWire (..),
    CaveatPayloadWire (..),
    ConsistencyWire (..),
    CaveatContextWire (..),
    CheckRequestWire (..),
    CheckDecisionWire (..),
    CaveatObligationWire (..),
    CheckResponseWire (..),
    BatchCheckPairWire (..),
    BatchCheckRequestWire (..),
    BatchCheckResponseWire (..),
    LookupRequestWire (..),
    LookupObjectWire (..),
    LookupStateWire (..),
    LookupPageWire (..),
    ExpandRequestWire (..),
    ExpandNodeWire (..),
    ExpandStateWire (..),
    ExpandTreeWire (..),
    WriteTuplesRequestWire (..),
    WriteTuplesResponseWire (..),
    DeleteTuplesRequestWire (..),
    objectRefToWire,
    objectRefFromWire,
    subjectToWire,
    subjectFromWire,
    tupleToWire,
    tupleFromWire,
    consistencyToWire,
    consistencyFromWire,
) where

import Control.Monad.IO.Class (liftIO)
import Control.Monad.Trans.Class (lift)
import Control.Monad.Trans.Except (ExceptT (..), runExceptT, throwE)
import Data.Aeson (
    FromJSON (..),
    Object,
    ToJSON (..),
    pairs,
    withObject,
    (.:),
    (.:?),
    (.=),
 )
import Data.Aeson qualified as Aeson
import Data.Aeson.Types (Parser)
import Data.Map.Strict (Map)
import Data.SOP (I (..), NS (..))
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Time (UTCTime)
import Data.Word (Word64)
import Effectful (Eff, IOE)
import Effectful qualified
import Effectful.Error.Static (Error)
import GHC.Clock (getMonotonicTimeNSec)
import GHC.TypeLits (Symbol)
import Servant (
    Application,
    Context (..),
    Handler,
    JSON,
    Proxy (..),
    ReqBody,
    Server,
    StdMethod (..),
    serveWithContext,
    type (:<|>) (..),
    type (:>),
 )
import Servant.API.MultiVerb (AsUnion (..), MultiVerb, Respond)
import Servant.Server (ErrorFormatter, ErrorFormatters (..), defaultErrorFormatters)

import En.Check (BatchPair (..), CaveatObligation (..), CheckDecision (..), checkMany)
import En.Effect.ConsistencyStore (ConsistencyStore)
import En.Effect.TupleStore (TupleStore, deleteTuples, writeTuples)
import En.Error (EnError)
import En.Expand qualified as Expand
import En.Lookup qualified as Lookup
import En.Revision (Consistency (..), ConsistencyToken (..))
import En.Schema (CaveatName (..), ObjectType (..), RelationName (..))
import En.Servant.Seam (
    EnFault (..),
    EnServer,
    Env (..),
    ErrorEnvelopeWire (..),
    badRequest,
    batchTooLarge,
    faultToServerError,
    invalidRequest,
    runEngineEither,
 )
import En.Servant.Seam qualified as Seam
import En.Tuple (
    CaveatContext (..),
    CaveatPayload (..),
    CaveatValue (..),
    ObjectRef (..),
    Subject (..),
    Tuple (..),
    TupleCaveat (..),
 )

{- | The statuses any en operation can answer with, as response alternatives of the
API type. Making them part of the type is what puts them in the generated OpenAPI
document and in @en-client@'s result type, instead of leaving them as untyped
'Servant.ServerError's thrown from a handler.

All six operations share this list even though a write cannot in practice exceed a
traversal bound (422). 'En.Error.EnError' is one closed sum shared by every operation,
so the type system cannot prove the write path never yields 'ResolutionLimitExceeded';
a narrower list for writes would make 'faultToResult' partial. A total conversion is
worth a slightly over-broad document.

Not covered here: errors raised before a handler runs. A malformed body or an unmatched
route comes from Servant's routing layer ('envelopeFormatters'), and
authentication/rate-limit rejections come from WAI middleware in @en-server@. All of
them still carry 'ErrorEnvelopeWire'.
-}
type EnResponses (description :: Symbol) a =
    '[ Respond 200 description a
     , Respond 400 "Invalid request" ErrorEnvelopeWire
     , Respond 422 "Resolution limit exceeded" ErrorEnvelopeWire
     , Respond 503 "Tuple store unavailable" ErrorEnvelopeWire
     ]

-- | What an en handler returns. 'AsUnion' maps it onto 'EnResponses' positionally.
data EnResult a
    = EnOk a
    | -- | 400
      EnClientError !ErrorEnvelopeWire
    | -- | 422
      EnUnprocessable !ErrorEnvelopeWire
    | -- | 503
      EnUnavailable !ErrorEnvelopeWire
    deriving stock (Eq, Show)

{- | Written by hand rather than derived through 'GenericAsUnion': the correspondence
between constructor and response alternative is the thing worth stating explicitly,
and a change to 'EnResponses' should break this instance loudly.
-}
instance
    AsUnion
        '[ Respond 200 description a
         , Respond 400 "Invalid request" ErrorEnvelopeWire
         , Respond 422 "Resolution limit exceeded" ErrorEnvelopeWire
         , Respond 503 "Tuple store unavailable" ErrorEnvelopeWire
         ]
        (EnResult a)
    where
    toUnion = \case
        EnOk value -> Z (I value)
        EnClientError envelope -> S (Z (I envelope))
        EnUnprocessable envelope -> S (S (Z (I envelope)))
        EnUnavailable envelope -> S (S (S (Z (I envelope))))
    fromUnion = \case
        Z (I value) -> EnOk value
        S (Z (I envelope)) -> EnClientError envelope
        S (S (Z (I envelope))) -> EnUnprocessable envelope
        S (S (S (Z (I envelope)))) -> EnUnavailable envelope
        S (S (S (S impossible))) -> case impossible of {}

-- | Every 'EnFault' has a home in 'EnResponses'. This totality is why the list is shared.
faultToResult :: EnFault -> EnResult a
faultToResult = \case
    BadRequestFault envelope -> EnClientError envelope
    UnprocessableFault envelope -> EnUnprocessable envelope
    UnavailableFault envelope -> EnUnavailable envelope

{- | The wire contract is versioned by path. @\/v1@ is current; a future breaking
change ships as @\/v2@ served alongside it, rather than mutating these operations.

Deletion is a @POST@ to @\/v1\/relationships\/delete@, not a @DELETE@ carrying a
request body: HTTP intermediaries are permitted to drop a @DELETE@ body.
-}
type EnAPI =
    "v1"
        :> ( "relationships"
                :> ReqBody '[JSON] WriteTuplesRequestWire
                :> MultiVerb 'POST '[JSON] (EnResponses "Consistency token for the write" WriteTuplesResponseWire) (EnResult WriteTuplesResponseWire)
                :<|> "relationships"
                    :> "delete"
                    :> ReqBody '[JSON] DeleteTuplesRequestWire
                    :> MultiVerb 'POST '[JSON] (EnResponses "Consistency token for the deletion" WriteTuplesResponseWire) (EnResult WriteTuplesResponseWire)
                :<|> "check"
                    :> ReqBody '[JSON] CheckRequestWire
                    :> MultiVerb 'POST '[JSON] (EnResponses "The authorization decision" CheckResponseWire) (EnResult CheckResponseWire)
                :<|> "batch-check"
                    :> ReqBody '[JSON] BatchCheckRequestWire
                    :> MultiVerb 'POST '[JSON] (EnResponses "One decision per requested pair, in order" BatchCheckResponseWire) (EnResult BatchCheckResponseWire)
                :<|> "lookup"
                    :> ReqBody '[JSON] LookupRequestWire
                    :> MultiVerb 'POST '[JSON] (EnResponses "A page of authorized objects" LookupPageWire) (EnResult LookupPageWire)
                :<|> "expand"
                    :> ReqBody '[JSON] ExpandRequestWire
                    :> MultiVerb 'POST '[JSON] (EnResponses "The permission's subject tree" ExpandTreeWire) (EnResult ExpandTreeWire)
           )

apiProxy :: Proxy EnAPI
apiProxy = Proxy

server :: (ConsistencyStore Effectful.:> es, TupleStore Effectful.:> es, Error EnError Effectful.:> es, IOE Effectful.:> es) => Env es -> Server EnAPI
server env =
    writeTuplesHandler env
        :<|> deleteTuplesHandler env
        :<|> checkHandler env
        :<|> batchCheckHandler env
        :<|> lookupHandler env
        :<|> expandHandler env

app :: (ConsistencyStore Effectful.:> es, TupleStore Effectful.:> es, Error EnError Effectful.:> es, IOE Effectful.:> es) => Env es -> Application
app env =
    serveWithContext apiProxy (envelopeFormatters :. EmptyContext) (server env)

{- | Make Servant's own errors speak the same envelope as en's.

A request that fails to parse, or that matches no route, is rejected before any
handler runs, so it cannot be a 'MultiVerb' response alternative. Without this the
caller would get Servant's plain-text body and an inconsistent error content type.

Not covered: @405 Method Not Allowed@ and @415 Unsupported Media Type@, which Servant
raises outside 'ErrorFormatters'. Both currently return an empty body. A 405 is what
@DELETE \/v1\/relationships@ now yields, and it notably does not consume the request
body — which is the reason deletion moved to @POST@.
-}
envelopeFormatters :: ErrorFormatters
envelopeFormatters =
    defaultErrorFormatters
        { bodyParserErrorFormatter = malformedBody
        , urlParseErrorFormatter = malformedBody
        , notFoundErrorFormatter = const Seam.notFound
        }
  where
    malformedBody :: ErrorFormatter
    malformedBody _typeRep _request detail =
        faultToServerError (badRequest "malformed_request_body" (Text.pack detail))

{- The JSON below is the public contract. Every instance in this section is written by
hand so that the wire shape is a reviewed artifact rather than a side effect of
generic derivation — which, for sum types, would leak Haskell constructor names as
{"tag": "AllowedWire"}. Each sum type carries a string discriminator field naming its
variant: `kind` for subjects and expand nodes, `mode` for consistency, `result` for
decisions, `status` for page states, and `type` for caveat values (matching the
storage encoding in En.Postgres.TupleStore).

Both toJSON and toEncoding are defined for every type. Data.Aeson.encode goes through
toEncoding, so writing it explicitly both skips the intermediate Value on the response
path and fixes field order, which is what lets the golden tests in
en-servant/test/Main.hs compare exact bytes.
-}

-- | Fail a decode with a message naming the discriminator and its legal values.
unknownVariant :: String -> Text -> [Text] -> Parser a
unknownVariant description value allowed =
    fail $
        "unknown "
            <> description
            <> " "
            <> show value
            <> "; expected "
            <> Text.unpack (Text.intercalate ", " allowed)

data ObjectRefWire = ObjectRefWire
    { objectType :: !Text
    , objectId :: !Text
    }
    deriving stock (Eq, Show)

instance ToJSON ObjectRefWire where
    toJSON wire = Aeson.object ["objectType" .= wire.objectType, "objectId" .= wire.objectId]
    toEncoding wire = pairs ("objectType" .= wire.objectType <> "objectId" .= wire.objectId)

instance FromJSON ObjectRefWire where
    parseJSON = withObject "ObjectRefWire" objectRefFields

-- | The @objectType@/@objectId@ pair, which subjects inline rather than nest.
objectRefFields :: Object -> Parser ObjectRefWire
objectRefFields o =
    ObjectRefWire <$> o .: "objectType" <*> o .: "objectId"

data SubjectWire
    = SubjectIdWire !ObjectRefWire
    | SubjectSetWire !ObjectRefWire !Text
    | SubjectWildcardWire !Text
    deriving stock (Eq, Show)

instance ToJSON SubjectWire where
    toJSON = \case
        SubjectIdWire ref ->
            Aeson.object ["kind" .= ("id" :: Text), "objectType" .= ref.objectType, "objectId" .= ref.objectId]
        SubjectSetWire ref relation ->
            Aeson.object
                [ "kind" .= ("set" :: Text)
                , "objectType" .= ref.objectType
                , "objectId" .= ref.objectId
                , "relation" .= relation
                ]
        SubjectWildcardWire objectType ->
            Aeson.object ["kind" .= ("wildcard" :: Text), "objectType" .= objectType]
    toEncoding = \case
        SubjectIdWire ref ->
            pairs ("kind" .= ("id" :: Text) <> "objectType" .= ref.objectType <> "objectId" .= ref.objectId)
        SubjectSetWire ref relation ->
            pairs
                ( "kind" .= ("set" :: Text)
                    <> "objectType" .= ref.objectType
                    <> "objectId" .= ref.objectId
                    <> "relation" .= relation
                )
        SubjectWildcardWire objectType ->
            pairs ("kind" .= ("wildcard" :: Text) <> "objectType" .= objectType)

instance FromJSON SubjectWire where
    parseJSON = withObject "SubjectWire" \o ->
        o .: "kind" >>= \case
            "id" -> SubjectIdWire <$> objectRefFields o
            "set" -> SubjectSetWire <$> objectRefFields o <*> o .: "relation"
            "wildcard" -> SubjectWildcardWire <$> o .: "objectType"
            other -> unknownVariant "subject kind" other ["id", "set", "wildcard"]

data CaveatValueWire
    = ValueTextWire !Text
    | ValueBoolWire !Bool
    | ValueIntegerWire !Integer
    | ValueTimestampWire !UTCTime
    | ValueEnumWire !Text
    deriving stock (Eq, Show)

instance ToJSON CaveatValueWire where
    toJSON = \case
        ValueTextWire value -> Aeson.object ["type" .= ("text" :: Text), "value" .= value]
        ValueBoolWire value -> Aeson.object ["type" .= ("bool" :: Text), "value" .= value]
        ValueIntegerWire value -> Aeson.object ["type" .= ("integer" :: Text), "value" .= value]
        ValueTimestampWire value -> Aeson.object ["type" .= ("timestamp" :: Text), "value" .= value]
        ValueEnumWire value -> Aeson.object ["type" .= ("enum" :: Text), "value" .= value]
    toEncoding = \case
        ValueTextWire value -> pairs ("type" .= ("text" :: Text) <> "value" .= value)
        ValueBoolWire value -> pairs ("type" .= ("bool" :: Text) <> "value" .= value)
        ValueIntegerWire value -> pairs ("type" .= ("integer" :: Text) <> "value" .= value)
        ValueTimestampWire value -> pairs ("type" .= ("timestamp" :: Text) <> "value" .= value)
        ValueEnumWire value -> pairs ("type" .= ("enum" :: Text) <> "value" .= value)

instance FromJSON CaveatValueWire where
    parseJSON = withObject "CaveatValueWire" \o ->
        o .: "type" >>= \case
            "text" -> ValueTextWire <$> o .: "value"
            "bool" -> ValueBoolWire <$> o .: "value"
            "integer" -> ValueIntegerWire <$> o .: "value"
            "timestamp" -> ValueTimestampWire <$> o .: "value"
            "enum" -> ValueEnumWire <$> o .: "value"
            other ->
                unknownVariant
                    "caveat value type"
                    other
                    ["text", "bool", "integer", "timestamp", "enum"]

newtype CaveatPayloadWire = CaveatPayloadWire
    { values :: Map Text CaveatValueWire
    }
    deriving stock (Eq, Show)

instance ToJSON CaveatPayloadWire where
    toJSON wire = Aeson.object ["values" .= wire.values]
    toEncoding wire = pairs ("values" .= wire.values)

instance FromJSON CaveatPayloadWire where
    parseJSON = withObject "CaveatPayloadWire" \o -> CaveatPayloadWire <$> o .: "values"

newtype CaveatContextWire = CaveatContextWire
    { values :: Map Text CaveatValueWire
    }
    deriving stock (Eq, Show)

instance ToJSON CaveatContextWire where
    toJSON wire = Aeson.object ["values" .= wire.values]
    toEncoding wire = pairs ("values" .= wire.values)

instance FromJSON CaveatContextWire where
    parseJSON = withObject "CaveatContextWire" \o -> CaveatContextWire <$> o .: "values"

data TupleCaveatWire = TupleCaveatWire
    { name :: !Text
    , payload :: !CaveatPayloadWire
    }
    deriving stock (Eq, Show)

instance ToJSON TupleCaveatWire where
    toJSON wire = Aeson.object ["name" .= wire.name, "payload" .= wire.payload]
    toEncoding wire = pairs ("name" .= wire.name <> "payload" .= wire.payload)

instance FromJSON TupleCaveatWire where
    parseJSON = withObject "TupleCaveatWire" \o ->
        TupleCaveatWire <$> o .: "name" <*> o .: "payload"

data TupleWire = TupleWire
    { object :: !ObjectRefWire
    , relation :: !Text
    , subject :: !SubjectWire
    , caveat :: !(Maybe TupleCaveatWire)
    }
    deriving stock (Eq, Show)

instance ToJSON TupleWire where
    toJSON wire =
        Aeson.object
            [ "object" .= wire.object
            , "relation" .= wire.relation
            , "subject" .= wire.subject
            , "caveat" .= wire.caveat
            ]
    toEncoding wire =
        pairs
            ( "object" .= wire.object
                <> "relation" .= wire.relation
                <> "subject" .= wire.subject
                <> "caveat" .= wire.caveat
            )

instance FromJSON TupleWire where
    parseJSON = withObject "TupleWire" \o ->
        TupleWire <$> o .: "object" <*> o .: "relation" <*> o .: "subject" <*> o .:? "caveat"

data ConsistencyWire
    = MinimizeLatencyWire
    | FullyConsistentWire
    | AtLeastAsFreshWire !Text
    | AtExactSnapshotWire !Text
    deriving stock (Eq, Show)

instance ToJSON ConsistencyWire where
    toJSON = \case
        MinimizeLatencyWire -> Aeson.object ["mode" .= ("minimizeLatency" :: Text)]
        FullyConsistentWire -> Aeson.object ["mode" .= ("fullyConsistent" :: Text)]
        AtLeastAsFreshWire token -> Aeson.object ["mode" .= ("atLeastAsFresh" :: Text), "token" .= token]
        AtExactSnapshotWire token -> Aeson.object ["mode" .= ("atExactSnapshot" :: Text), "token" .= token]
    toEncoding = \case
        MinimizeLatencyWire -> pairs ("mode" .= ("minimizeLatency" :: Text))
        FullyConsistentWire -> pairs ("mode" .= ("fullyConsistent" :: Text))
        AtLeastAsFreshWire token -> pairs ("mode" .= ("atLeastAsFresh" :: Text) <> "token" .= token)
        AtExactSnapshotWire token -> pairs ("mode" .= ("atExactSnapshot" :: Text) <> "token" .= token)

instance FromJSON ConsistencyWire where
    parseJSON = withObject "ConsistencyWire" \o ->
        o .: "mode" >>= \case
            "minimizeLatency" -> pure MinimizeLatencyWire
            "fullyConsistent" -> pure FullyConsistentWire
            "atLeastAsFresh" -> AtLeastAsFreshWire <$> o .: "token"
            "atExactSnapshot" -> AtExactSnapshotWire <$> o .: "token"
            other ->
                unknownVariant
                    "consistency mode"
                    other
                    ["minimizeLatency", "fullyConsistent", "atLeastAsFresh", "atExactSnapshot"]

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

data CheckDecisionWire
    = AllowedWire
    | DeniedWire
    | ConditionalWire ![CaveatObligationWire]
    deriving stock (Eq, Show)

instance ToJSON CheckDecisionWire where
    toJSON = \case
        AllowedWire -> Aeson.object ["result" .= ("allowed" :: Text)]
        DeniedWire -> Aeson.object ["result" .= ("denied" :: Text)]
        ConditionalWire obligations ->
            Aeson.object ["result" .= ("conditional" :: Text), "obligations" .= obligations]
    toEncoding = \case
        AllowedWire -> pairs ("result" .= ("allowed" :: Text))
        DeniedWire -> pairs ("result" .= ("denied" :: Text))
        ConditionalWire obligations ->
            pairs ("result" .= ("conditional" :: Text) <> "obligations" .= obligations)

instance FromJSON CheckDecisionWire where
    parseJSON = withObject "CheckDecisionWire" \o ->
        o .: "result" >>= \case
            "allowed" -> pure AllowedWire
            "denied" -> pure DeniedWire
            "conditional" -> ConditionalWire <$> o .: "obligations"
            other -> unknownVariant "check result" other ["allowed", "denied", "conditional"]

data CaveatObligationWire = CaveatObligationWire
    { caveat :: !Text
    , missingContext :: ![Text]
    }
    deriving stock (Eq, Show)

instance ToJSON CaveatObligationWire where
    toJSON wire = Aeson.object ["caveat" .= wire.caveat, "missingContext" .= wire.missingContext]
    toEncoding wire = pairs ("caveat" .= wire.caveat <> "missingContext" .= wire.missingContext)

instance FromJSON CaveatObligationWire where
    parseJSON = withObject "CaveatObligationWire" \o ->
        CaveatObligationWire <$> o .: "caveat" <*> o .: "missingContext"

newtype CheckResponseWire = CheckResponseWire
    { decision :: CheckDecisionWire
    }
    deriving stock (Eq, Show)

instance ToJSON CheckResponseWire where
    toJSON wire = Aeson.object ["decision" .= wire.decision]
    toEncoding wire = pairs ("decision" .= wire.decision)

instance FromJSON CheckResponseWire where
    parseJSON = withObject "CheckResponseWire" \o -> CheckResponseWire <$> o .: "decision"

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

newtype BatchCheckResponseWire = BatchCheckResponseWire
    { decisions :: [CheckDecisionWire]
    }
    deriving stock (Eq, Show)

instance ToJSON BatchCheckResponseWire where
    toJSON wire = Aeson.object ["decisions" .= wire.decisions]
    toEncoding wire = pairs ("decisions" .= wire.decisions)

instance FromJSON BatchCheckResponseWire where
    parseJSON = withObject "BatchCheckResponseWire" \o -> BatchCheckResponseWire <$> o .: "decisions"

data LookupRequestWire = LookupRequestWire
    { consistency :: !ConsistencyWire
    , subject :: !SubjectWire
    , permission :: !Text
    , objectType :: !Text
    , context :: !CaveatContextWire
    , limit :: !Int
    , cursor :: !(Maybe Text)
    , deadlineMillis :: !(Maybe Int)
    }
    deriving stock (Eq, Show)

instance ToJSON LookupRequestWire where
    toJSON wire =
        Aeson.object
            [ "consistency" .= wire.consistency
            , "subject" .= wire.subject
            , "permission" .= wire.permission
            , "objectType" .= wire.objectType
            , "context" .= wire.context
            , "limit" .= wire.limit
            , "cursor" .= wire.cursor
            , "deadlineMillis" .= wire.deadlineMillis
            ]
    toEncoding wire =
        pairs
            ( "consistency" .= wire.consistency
                <> "subject" .= wire.subject
                <> "permission" .= wire.permission
                <> "objectType" .= wire.objectType
                <> "context" .= wire.context
                <> "limit" .= wire.limit
                <> "cursor" .= wire.cursor
                <> "deadlineMillis" .= wire.deadlineMillis
            )

instance FromJSON LookupRequestWire where
    parseJSON = withObject "LookupRequestWire" \o ->
        LookupRequestWire
            <$> o .: "consistency"
            <*> o .: "subject"
            <*> o .: "permission"
            <*> o .: "objectType"
            <*> o .: "context"
            <*> o .: "limit"
            <*> o .:? "cursor"
            <*> o .:? "deadlineMillis"

data LookupObjectWire = LookupObjectWire
    { object :: !ObjectRefWire
    , decision :: !CheckDecisionWire
    }
    deriving stock (Eq, Show)

instance ToJSON LookupObjectWire where
    toJSON wire = Aeson.object ["object" .= wire.object, "decision" .= wire.decision]
    toEncoding wire = pairs ("object" .= wire.object <> "decision" .= wire.decision)

instance FromJSON LookupObjectWire where
    parseJSON = withObject "LookupObjectWire" \o ->
        LookupObjectWire <$> o .: "object" <*> o .: "decision"

data LookupStateWire
    = LookupExhaustedWire
    | LookupHasMoreWire !Text
    | LookupTruncatedWire !Text
    deriving stock (Eq, Show)

instance ToJSON LookupStateWire where
    toJSON = \case
        LookupExhaustedWire -> Aeson.object ["status" .= ("exhausted" :: Text)]
        LookupHasMoreWire cursor -> Aeson.object ["status" .= ("hasMore" :: Text), "cursor" .= cursor]
        LookupTruncatedWire cursor -> Aeson.object ["status" .= ("truncated" :: Text), "cursor" .= cursor]
    toEncoding = \case
        LookupExhaustedWire -> pairs ("status" .= ("exhausted" :: Text))
        LookupHasMoreWire cursor -> pairs ("status" .= ("hasMore" :: Text) <> "cursor" .= cursor)
        LookupTruncatedWire cursor -> pairs ("status" .= ("truncated" :: Text) <> "cursor" .= cursor)

instance FromJSON LookupStateWire where
    parseJSON = withObject "LookupStateWire" \o ->
        o .: "status" >>= \case
            "exhausted" -> pure LookupExhaustedWire
            "hasMore" -> LookupHasMoreWire <$> o .: "cursor"
            "truncated" -> LookupTruncatedWire <$> o .: "cursor"
            other -> unknownVariant "lookup status" other ["exhausted", "hasMore", "truncated"]

data LookupPageWire = LookupPageWire
    { objects :: ![LookupObjectWire]
    , state :: !LookupStateWire
    }
    deriving stock (Eq, Show)

instance ToJSON LookupPageWire where
    toJSON wire = Aeson.object ["objects" .= wire.objects, "state" .= wire.state]
    toEncoding wire = pairs ("objects" .= wire.objects <> "state" .= wire.state)

instance FromJSON LookupPageWire where
    parseJSON = withObject "LookupPageWire" \o ->
        LookupPageWire <$> o .: "objects" <*> o .: "state"

data ExpandRequestWire = ExpandRequestWire
    { consistency :: !ConsistencyWire
    , object :: !ObjectRefWire
    , permission :: !Text
    , context :: !CaveatContextWire
    , limit :: !Int
    , cursor :: !(Maybe Text)
    }
    deriving stock (Eq, Show)

instance ToJSON ExpandRequestWire where
    toJSON wire =
        Aeson.object
            [ "consistency" .= wire.consistency
            , "object" .= wire.object
            , "permission" .= wire.permission
            , "context" .= wire.context
            , "limit" .= wire.limit
            , "cursor" .= wire.cursor
            ]
    toEncoding wire =
        pairs
            ( "consistency" .= wire.consistency
                <> "object" .= wire.object
                <> "permission" .= wire.permission
                <> "context" .= wire.context
                <> "limit" .= wire.limit
                <> "cursor" .= wire.cursor
            )

instance FromJSON ExpandRequestWire where
    parseJSON = withObject "ExpandRequestWire" \o ->
        ExpandRequestWire
            <$> o .: "consistency"
            <*> o .: "object"
            <*> o .: "permission"
            <*> o .: "context"
            <*> o .: "limit"
            <*> o .:? "cursor"

data ExpandNodeWire
    = ExpandSubjectWire !SubjectWire
    | ExpandUsersetWire !ObjectRefWire !Text ![ExpandNodeWire]
    | ExpandCaveatedWire !Text ![ExpandNodeWire]
    deriving stock (Eq, Show)

instance ToJSON ExpandNodeWire where
    toJSON = \case
        ExpandSubjectWire subject ->
            Aeson.object ["kind" .= ("subject" :: Text), "subject" .= subject]
        ExpandUsersetWire ref relation children ->
            Aeson.object
                [ "kind" .= ("userset" :: Text)
                , "object" .= ref
                , "relation" .= relation
                , "children" .= children
                ]
        ExpandCaveatedWire caveat children ->
            Aeson.object ["kind" .= ("caveated" :: Text), "caveat" .= caveat, "children" .= children]
    toEncoding = \case
        ExpandSubjectWire subject ->
            pairs ("kind" .= ("subject" :: Text) <> "subject" .= subject)
        ExpandUsersetWire ref relation children ->
            pairs
                ( "kind" .= ("userset" :: Text)
                    <> "object" .= ref
                    <> "relation" .= relation
                    <> "children" .= children
                )
        ExpandCaveatedWire caveat children ->
            pairs ("kind" .= ("caveated" :: Text) <> "caveat" .= caveat <> "children" .= children)

instance FromJSON ExpandNodeWire where
    parseJSON = withObject "ExpandNodeWire" \o ->
        o .: "kind" >>= \case
            "subject" -> ExpandSubjectWire <$> o .: "subject"
            "userset" -> ExpandUsersetWire <$> o .: "object" <*> o .: "relation" <*> o .: "children"
            "caveated" -> ExpandCaveatedWire <$> o .: "caveat" <*> o .: "children"
            other -> unknownVariant "expand node kind" other ["subject", "userset", "caveated"]

data ExpandStateWire
    = ExpandExhaustedWire
    | ExpandHasMoreWire !Text
    | ExpandTruncatedWire !Text
    deriving stock (Eq, Show)

instance ToJSON ExpandStateWire where
    toJSON = \case
        ExpandExhaustedWire -> Aeson.object ["status" .= ("exhausted" :: Text)]
        ExpandHasMoreWire cursor -> Aeson.object ["status" .= ("hasMore" :: Text), "cursor" .= cursor]
        ExpandTruncatedWire cursor -> Aeson.object ["status" .= ("truncated" :: Text), "cursor" .= cursor]
    toEncoding = \case
        ExpandExhaustedWire -> pairs ("status" .= ("exhausted" :: Text))
        ExpandHasMoreWire cursor -> pairs ("status" .= ("hasMore" :: Text) <> "cursor" .= cursor)
        ExpandTruncatedWire cursor -> pairs ("status" .= ("truncated" :: Text) <> "cursor" .= cursor)

instance FromJSON ExpandStateWire where
    parseJSON = withObject "ExpandStateWire" \o ->
        o .: "status" >>= \case
            "exhausted" -> pure ExpandExhaustedWire
            "hasMore" -> ExpandHasMoreWire <$> o .: "cursor"
            "truncated" -> ExpandTruncatedWire <$> o .: "cursor"
            other -> unknownVariant "expand status" other ["exhausted", "hasMore", "truncated"]

data ExpandTreeWire = ExpandTreeWire
    { root :: !ObjectRefWire
    , permission :: !Text
    , children :: ![ExpandNodeWire]
    , state :: !ExpandStateWire
    }
    deriving stock (Eq, Show)

instance ToJSON ExpandTreeWire where
    toJSON wire =
        Aeson.object
            [ "root" .= wire.root
            , "permission" .= wire.permission
            , "children" .= wire.children
            , "state" .= wire.state
            ]
    toEncoding wire =
        pairs
            ( "root" .= wire.root
                <> "permission" .= wire.permission
                <> "children" .= wire.children
                <> "state" .= wire.state
            )

instance FromJSON ExpandTreeWire where
    parseJSON = withObject "ExpandTreeWire" \o ->
        ExpandTreeWire <$> o .: "root" <*> o .: "permission" <*> o .: "children" <*> o .: "state"

newtype WriteTuplesRequestWire = WriteTuplesRequestWire
    { tuples :: [TupleWire]
    }
    deriving stock (Eq, Show)

instance ToJSON WriteTuplesRequestWire where
    toJSON wire = Aeson.object ["tuples" .= wire.tuples]
    toEncoding wire = pairs ("tuples" .= wire.tuples)

instance FromJSON WriteTuplesRequestWire where
    parseJSON = withObject "WriteTuplesRequestWire" \o -> WriteTuplesRequestWire <$> o .: "tuples"

newtype DeleteTuplesRequestWire = DeleteTuplesRequestWire
    { tuples :: [TupleWire]
    }
    deriving stock (Eq, Show)

instance ToJSON DeleteTuplesRequestWire where
    toJSON wire = Aeson.object ["tuples" .= wire.tuples]
    toEncoding wire = pairs ("tuples" .= wire.tuples)

instance FromJSON DeleteTuplesRequestWire where
    parseJSON = withObject "DeleteTuplesRequestWire" \o -> DeleteTuplesRequestWire <$> o .: "tuples"

newtype WriteTuplesResponseWire = WriteTuplesResponseWire
    { token :: Text
    }
    deriving stock (Eq, Show)

instance ToJSON WriteTuplesResponseWire where
    toJSON wire = Aeson.object ["token" .= wire.token]
    toEncoding wire = pairs ("token" .= wire.token)

instance FromJSON WriteTuplesResponseWire where
    parseJSON = withObject "WriteTuplesResponseWire" \o -> WriteTuplesResponseWire <$> o .: "token"

{- | Run a handler body that may fail with an 'EnFault', turning either outcome into
the 'EnResult' the operation's 'MultiVerb' response list expects.

Handlers return faults rather than throwing them, which is what keeps every status
they can produce visible in 'EnAPI'.
-}
enHandler :: ExceptT EnFault Handler a -> Handler (EnResult a)
enHandler body =
    either faultToResult EnOk <$> runExceptT body

writeTuplesHandler :: (TupleStore Effectful.:> es) => Env es -> WriteTuplesRequestWire -> Handler (EnResult WriteTuplesResponseWire)
writeTuplesHandler env request = enHandler do
    tuples <- traverseOrInvalid tupleFromWire request.tuples
    token <- engine env (writeTuples tuples)
    pure (tokenToWire token)

deleteTuplesHandler :: (TupleStore Effectful.:> es) => Env es -> DeleteTuplesRequestWire -> Handler (EnResult WriteTuplesResponseWire)
deleteTuplesHandler env request = enHandler do
    tuples <- traverseOrInvalid tupleFromWire request.tuples
    token <- engine env (deleteTuples tuples)
    pure (tokenToWire token)

checkHandler :: Env es -> CheckRequestWire -> Handler (EnResult CheckResponseWire)
checkHandler env request = enHandler do
    consistency <- orInvalid (consistencyFromWire request.consistency)
    context <- orInvalid (contextFromWire request.context)
    subject <- orInvalid (subjectFromWire request.subject)
    object <- orInvalid (objectRefFromWire request.object)
    decision <-
        engine
            env
            ( env.checkOperation
                env.graph
                consistency
                context
                subject
                (RelationName request.permission)
                object
            )
    pure CheckResponseWire{decision = decisionToWire decision}

batchCheckHandler :: (ConsistencyStore Effectful.:> es, TupleStore Effectful.:> es) => Env es -> BatchCheckRequestWire -> Handler (EnResult BatchCheckResponseWire)
batchCheckHandler env request = enHandler do
    if length request.pairs > env.maxBatchSize
        then
            throwE
                (batchTooLarge ("batch exceeds the maximum of " <> Text.pack (show env.maxBatchSize) <> " pairs"))
        else pure ()
    consistency <- orInvalid (consistencyFromWire request.consistency)
    context <- orInvalid (contextFromWire request.context)
    batchPairs <- traverseOrInvalid pairFromWire request.pairs
    decisions <-
        engine
            env
            ( checkMany
                env.graph
                consistency
                context
                batchPairs
            )
    pure BatchCheckResponseWire{decisions = decisionToWire <$> decisions}
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

lookupHandler :: (IOE Effectful.:> es) => Env es -> LookupRequestWire -> Handler (EnResult LookupPageWire)
lookupHandler env request = enHandler do
    consistency <- orInvalid (consistencyFromWire request.consistency)
    context <- orInvalid (contextFromWire request.context)
    subject <- orInvalid (subjectFromWire request.subject)
    deadline <- lift (lookupDeadline request.deadlineMillis)
    page <-
        engine
            env
            ( env.lookupWithDeadlineOperation
                deadline
                env.graph
                consistency
                Lookup.LookupRequest
                    { subject
                    , permission = RelationName request.permission
                    , objectType = ObjectType request.objectType
                    , context
                    , limit = Lookup.LookupLimit request.limit
                    , cursor = Lookup.LookupCursor <$> request.cursor
                    }
            )
    pure (lookupPageToWire page)

lookupDeadline :: (IOE Effectful.:> es) => Maybe Int -> Handler (Lookup.Deadline (Eff es))
lookupDeadline maybeDeadlineMillis = do
    startedAt <- liftIO getMonotonicTimeNSec
    let budgetNs :: Word64
        budgetNs = fromIntegral (max 0 (maybe 3000 id maybeDeadlineMillis)) * 1000000
    pure $
        Lookup.Deadline $ do
            now <- Effectful.liftIO getMonotonicTimeNSec
            pure (now - startedAt <= budgetNs)

expandHandler :: (ConsistencyStore Effectful.:> es, TupleStore Effectful.:> es, Error EnError Effectful.:> es) => Env es -> ExpandRequestWire -> Handler (EnResult ExpandTreeWire)
expandHandler env request = enHandler do
    consistency <- orInvalid (consistencyFromWire request.consistency)
    context <- orInvalid (contextFromWire request.context)
    object <- orInvalid (objectRefFromWire request.object)
    tree <-
        engine
            env
            ( Expand.expand
                env.graph
                consistency
                Expand.ExpandRequest
                    { object
                    , permission = RelationName request.permission
                    , context
                    , limit = Expand.ExpandLimit request.limit
                    , cursor = Expand.ExpandCursor <$> request.cursor
                    }
            )
    pure (expandTreeToWire tree)

objectRefToWire :: ObjectRef -> ObjectRefWire
objectRefToWire ObjectRef{objectType = ObjectType objectType, objectId} =
    ObjectRefWire{objectType, objectId}

objectRefFromWire :: ObjectRefWire -> Either Text ObjectRef
objectRefFromWire ObjectRefWire{objectType, objectId}
    | Text.null objectType = Left "objectType must not be empty"
    | Text.null objectId = Left "objectId must not be empty"
    | otherwise = Right ObjectRef{objectType = ObjectType objectType, objectId}

subjectToWire :: Subject -> SubjectWire
subjectToWire =
    \case
        SubjectId object -> SubjectIdWire (objectRefToWire object)
        SubjectSet object (RelationName relation) -> SubjectSetWire (objectRefToWire object) relation
        SubjectWildcard (ObjectType objectType) -> SubjectWildcardWire objectType

subjectFromWire :: SubjectWire -> Either Text Subject
subjectFromWire =
    \case
        SubjectIdWire object -> SubjectId <$> objectRefFromWire object
        SubjectSetWire object relation
            | Text.null relation -> Left "subject relation must not be empty"
            | otherwise -> SubjectSet <$> objectRefFromWire object <*> Right (RelationName relation)
        SubjectWildcardWire objectType
            | Text.null objectType -> Left "wildcard subject objectType must not be empty"
            | otherwise -> Right (SubjectWildcard (ObjectType objectType))

tupleToWire :: Tuple -> TupleWire
tupleToWire Tuple{object, relation = RelationName relation, subject, caveat} =
    TupleWire
        { object = objectRefToWire object
        , relation
        , subject = subjectToWire subject
        , caveat = tupleCaveatToWire <$> caveat
        }

tupleFromWire :: TupleWire -> Either Text Tuple
tupleFromWire TupleWire{object, relation, subject, caveat}
    | Text.null relation = Left "relation must not be empty"
    | otherwise =
        Tuple
            <$> objectRefFromWire object
            <*> Right (RelationName relation)
            <*> subjectFromWire subject
            <*> traverse tupleCaveatFromWire caveat

tupleCaveatToWire :: TupleCaveat -> TupleCaveatWire
tupleCaveatToWire TupleCaveat{name = CaveatName name, payload} =
    TupleCaveatWire{name, payload = payloadToWire payload}

tupleCaveatFromWire :: TupleCaveatWire -> Either Text TupleCaveat
tupleCaveatFromWire TupleCaveatWire{name, payload}
    | Text.null name = Left "caveat name must not be empty"
    | otherwise = TupleCaveat (CaveatName name) <$> payloadFromWire payload

payloadToWire :: CaveatPayload -> CaveatPayloadWire
payloadToWire (CaveatPayload values) =
    CaveatPayloadWire (valueToWire <$> values)

payloadFromWire :: CaveatPayloadWire -> Either Text CaveatPayload
payloadFromWire (CaveatPayloadWire values) =
    CaveatPayload <$> traverse valueFromWire values

contextFromWire :: CaveatContextWire -> Either Text CaveatContext
contextFromWire (CaveatContextWire values) =
    CaveatContext <$> traverse valueFromWire values

valueToWire :: CaveatValue -> CaveatValueWire
valueToWire =
    \case
        ValueText value -> ValueTextWire value
        ValueBool value -> ValueBoolWire value
        ValueInteger value -> ValueIntegerWire value
        ValueTimestamp value -> ValueTimestampWire value
        ValueEnum value -> ValueEnumWire value

valueFromWire :: CaveatValueWire -> Either Text CaveatValue
valueFromWire =
    \case
        ValueTextWire value -> Right (ValueText value)
        ValueBoolWire value -> Right (ValueBool value)
        ValueIntegerWire value -> Right (ValueInteger value)
        ValueTimestampWire value -> Right (ValueTimestamp value)
        ValueEnumWire value -> Right (ValueEnum value)

consistencyToWire :: Consistency -> ConsistencyWire
consistencyToWire =
    \case
        MinimizeLatency -> MinimizeLatencyWire
        FullyConsistent -> FullyConsistentWire
        AtLeastAsFresh (ConsistencyToken token) -> AtLeastAsFreshWire token
        AtExactSnapshot (ConsistencyToken token) -> AtExactSnapshotWire token

consistencyFromWire :: ConsistencyWire -> Either Text Consistency
consistencyFromWire =
    \case
        MinimizeLatencyWire -> Right MinimizeLatency
        FullyConsistentWire -> Right FullyConsistent
        AtLeastAsFreshWire token
            | Text.null token -> Left "consistency token must not be empty"
            | otherwise -> Right (AtLeastAsFresh (ConsistencyToken token))
        AtExactSnapshotWire token
            | Text.null token -> Left "consistency token must not be empty"
            | otherwise -> Right (AtExactSnapshot (ConsistencyToken token))

tokenToWire :: ConsistencyToken -> WriteTuplesResponseWire
tokenToWire (ConsistencyToken token) =
    WriteTuplesResponseWire{token}

decisionToWire :: CheckDecision -> CheckDecisionWire
decisionToWire =
    \case
        Allowed -> AllowedWire
        Denied -> DeniedWire
        Conditional obligations -> ConditionalWire (obligationToWire <$> obligations)

obligationToWire :: CaveatObligation -> CaveatObligationWire
obligationToWire CaveatObligation{caveat = CaveatName caveat, missingContext} =
    CaveatObligationWire{caveat, missingContext}

lookupPageToWire :: Lookup.LookupPage -> LookupPageWire
lookupPageToWire Lookup.LookupPage{objects, state} =
    LookupPageWire
        { objects = lookupObjectToWire <$> objects
        , state = lookupStateToWire state
        }

lookupObjectToWire :: Lookup.LookupObject -> LookupObjectWire
lookupObjectToWire Lookup.LookupObject{object, decision} =
    LookupObjectWire{object = objectRefToWire object, decision = decisionToWire decision}

lookupStateToWire :: Lookup.LookupState -> LookupStateWire
lookupStateToWire =
    \case
        Lookup.LookupExhausted -> LookupExhaustedWire
        Lookup.LookupHasMore (Lookup.LookupCursor cursor) -> LookupHasMoreWire cursor
        Lookup.LookupTruncated (Lookup.LookupCursor cursor) -> LookupTruncatedWire cursor

expandTreeToWire :: Expand.ExpandTree -> ExpandTreeWire
expandTreeToWire Expand.ExpandTree{root, permission = RelationName permission, children, state} =
    ExpandTreeWire
        { root = objectRefToWire root
        , permission
        , children = expandNodeToWire <$> children
        , state = expandStateToWire state
        }

expandNodeToWire :: Expand.ExpandNode -> ExpandNodeWire
expandNodeToWire =
    \case
        Expand.ExpandSubject subject _row -> ExpandSubjectWire (subjectToWire subject)
        Expand.ExpandUserset object (RelationName relation) children ->
            ExpandUsersetWire (objectRefToWire object) relation (expandNodeToWire <$> children)
        Expand.ExpandCaveated (CaveatName caveat) children ->
            ExpandCaveatedWire caveat (expandNodeToWire <$> children)

expandStateToWire :: Expand.ExpandState -> ExpandStateWire
expandStateToWire =
    \case
        Expand.ExpandExhausted -> ExpandExhaustedWire
        Expand.ExpandHasMore (Expand.ExpandCursor cursor) -> ExpandHasMoreWire cursor
        Expand.ExpandTruncated (Expand.ExpandCursor cursor) -> ExpandTruncatedWire cursor

-- | Run an engine action, surfacing an 'En.Error.EnError' as an 'EnFault'.
engine :: Env es -> Eff es a -> ExceptT EnFault Handler a
engine env action =
    ExceptT (runEngineEither env action)

-- | A wire-to-engine conversion failure is a client fault, not an engine error.
orInvalid :: Either Text a -> ExceptT EnFault Handler a
orInvalid =
    either (throwE . invalidRequest) pure

traverseOrInvalid :: (a -> Either Text b) -> [a] -> ExceptT EnFault Handler [b]
traverseOrInvalid convert values =
    orInvalid (traverse convert values)
