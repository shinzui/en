{-# LANGUAGE TypeOperators #-}

-- | The en HTTP API as a Servant API type plus server handlers.
module En.Servant.API (
    EnAPI,
    apiProxy,
    EnServer,
    ActiveSchema (..),
    Env (..),
    server,
    app,
    envelopeFormatters,
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
    LookupSubjectsRequestWire (..),
    LookupSubjectWire (..),
    LookupSubjectsStateWire (..),
    LookupSubjectsPageWire (..),
    ExpandRequestWire (..),
    ExpandNodeWire (..),
    ExpandStateWire (..),
    ExpandTreeWire (..),
    WriteTuplesRequestWire (..),
    PreconditionWire (..),
    TupleFilterWire (..),
    SubjectRelationFilterWire (..),
    preconditionFromWire,
    WriteTuplesResponseWire (..),
    DeleteTuplesRequestWire (..),
    RelationshipFilterWire (..),
    ReadRelationshipsRequestWire (..),
    RelationshipsStateWire (..),
    ReadRelationshipsResponseWire (..),
    DeleteRelationshipsRequestWire (..),
    DeleteRelationshipsResponseWire (..),
    WatchRequestWire (..),
    ChangeKindWire (..),
    TupleChangeWire (..),
    WatchResponseWire (..),
    SchemaInfoWire (..),
    relationshipFilterFromWire,
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
import Data.Int (Int64)
import Data.Map.Strict (Map)
import Data.Maybe (fromMaybe)
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
    Get,
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

import En.Check (BatchOutcome (..), BatchPair (..), CaveatObligation (..), CheckDecision (..), CheckOutcome (..), checkMany)
import En.Effect.ConsistencyStore (ConsistencyStore, ResolvedConsistency (..), mintToken, resolveConsistency)
import En.Effect.TupleStore (
    ChangeKind (..),
    PageState (..),
    Precondition (..),
    RelationshipFilter (..),
    StoreCursor (..),
    SubjectRelationFilter (..),
    TupleChange (..),
    TupleFilter (..),
    TuplePage (..),
    TupleRow (..),
    TupleStore,
    TupleWriteRequest (..),
    applyTupleWrites,
    countRelationships,
    deleteRelationships,
    readRelationships,
    validateRelationshipFilter,
 )
import En.Error (EnError)
import En.Expand qualified as Expand
import En.Lookup qualified as Lookup
import En.LookupSubjects qualified as LookupSubjects

-- 'ReachabilityGraph' is imported for its @hash@ field, not its constructor: GHC solves the
-- @HasField "hash"@ constraint behind @active.graph.hash@ only when the field is in scope.
import En.Reachability (ReachabilityGraph (..))
import En.Revision (Consistency (..), ConsistencyToken (..), SchemaHash (..))
import En.Schema (CaveatName (..), ObjectType (..), RelationName (..))
import En.Servant.Seam (
    ActiveSchema (..),
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
import En.Watch qualified as Watch

{- | The statuses any en operation can answer with, as response alternatives of the
API type. Making them part of the type is what puts them in the generated OpenAPI
document and in @en-client@'s result type, instead of leaving them as untyped
'Servant.ServerError's thrown from a handler.

Every operation shares this list even though a write cannot in practice exceed a
traversal bound (422), and a read can never fail a write precondition (412).
'En.Error.EnError' is one closed sum shared by every operation, so the type system
cannot prove the write path never yields 'ResolutionLimitExceeded' nor that the read
path never yields 'WritePreconditionFailed'; a narrower list per operation would make
'faultToResult' partial. A total conversion is worth a slightly over-broad document.

Not covered here: errors raised before a handler runs. A malformed body or an unmatched
route comes from Servant's routing layer ('envelopeFormatters'), and
authentication/rate-limit rejections come from WAI middleware in @en-server@. All of
them still carry 'ErrorEnvelopeWire'.
-}
type EnResponses (description :: Symbol) a =
    '[ Respond 200 description a
     , Respond 400 "Invalid request" ErrorEnvelopeWire
     , Respond 412 "Write precondition failed" ErrorEnvelopeWire
     , Respond 422 "Resolution limit exceeded" ErrorEnvelopeWire
     , Respond 503 "Tuple store unavailable" ErrorEnvelopeWire
     ]

-- | What an en handler returns. 'AsUnion' maps it onto 'EnResponses' positionally.
data EnResult a
    = EnOk a
    | -- | 400
      EnClientError !ErrorEnvelopeWire
    | -- | 412
      EnPreconditionFailed !ErrorEnvelopeWire
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
         , Respond 412 "Write precondition failed" ErrorEnvelopeWire
         , Respond 422 "Resolution limit exceeded" ErrorEnvelopeWire
         , Respond 503 "Tuple store unavailable" ErrorEnvelopeWire
         ]
        (EnResult a)
    where
    toUnion = \case
        EnOk value -> Z (I value)
        EnClientError envelope -> S (Z (I envelope))
        EnPreconditionFailed envelope -> S (S (Z (I envelope)))
        EnUnprocessable envelope -> S (S (S (Z (I envelope))))
        EnUnavailable envelope -> S (S (S (S (Z (I envelope)))))
    fromUnion = \case
        Z (I value) -> EnOk value
        S (Z (I envelope)) -> EnClientError envelope
        S (S (Z (I envelope))) -> EnPreconditionFailed envelope
        S (S (S (Z (I envelope)))) -> EnUnprocessable envelope
        S (S (S (S (Z (I envelope))))) -> EnUnavailable envelope
        S (S (S (S (S impossible)))) -> case impossible of {}

-- | Every 'EnFault' has a home in 'EnResponses'. This totality is why the list is shared.
faultToResult :: EnFault -> EnResult a
faultToResult = \case
    BadRequestFault envelope -> EnClientError envelope
    PreconditionFailedFault envelope -> EnPreconditionFailed envelope
    UnprocessableFault envelope -> EnUnprocessable envelope
    UnavailableFault envelope -> EnUnavailable envelope

{- | The wire contract is versioned by path. @\/v1@ is current; a future breaking
change ships as @\/v2@ served alongside it, rather than mutating these operations.

Deletion is a @POST@ to @\/v1\/relationships\/delete@, not a @DELETE@ carrying a
request body: HTTP intermediaries are permitted to drop a @DELETE@ body.

@\/v1\/relationships\/delete@ retires the tuples a request /names/;
@\/v1\/relationships\/delete-by-filter@ retires every tuple a request /describes/. They
are separate operations rather than one that branches on the body, because "revoke these
three grants" and "revoke everything matching this pattern" must not differ by a typo.
The spelling diverges from SpiceDB, whose @DeleteRelationships@ is the filtered one; the
unfiltered path was here first and @v1@ is frozen.

@GET \/v1\/schema@ is the one operation that is not a @POST@ and not a 'MultiVerb': it reads
the server's own configuration out of memory, takes no body, and cannot fail.
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
                :<|> "relationships"
                    :> "query"
                    :> ReqBody '[JSON] ReadRelationshipsRequestWire
                    :> MultiVerb 'POST '[JSON] (EnResponses "A page of stored relationships" ReadRelationshipsResponseWire) (EnResult ReadRelationshipsResponseWire)
                :<|> "relationships"
                    :> "delete-by-filter"
                    :> ReqBody '[JSON] DeleteRelationshipsRequestWire
                    :> MultiVerb 'POST '[JSON] (EnResponses "How many relationships the filter matched" DeleteRelationshipsResponseWire) (EnResult DeleteRelationshipsResponseWire)
                :<|> "check"
                    :> ReqBody '[JSON] CheckRequestWire
                    :> MultiVerb 'POST '[JSON] (EnResponses "The authorization decision" CheckResponseWire) (EnResult CheckResponseWire)
                :<|> "batch-check"
                    :> ReqBody '[JSON] BatchCheckRequestWire
                    :> MultiVerb 'POST '[JSON] (EnResponses "One decision per requested pair, in order" BatchCheckResponseWire) (EnResult BatchCheckResponseWire)
                :<|> "lookup"
                    :> ReqBody '[JSON] LookupRequestWire
                    :> MultiVerb 'POST '[JSON] (EnResponses "A page of authorized objects" LookupPageWire) (EnResult LookupPageWire)
                :<|> "lookup-subjects"
                    :> ReqBody '[JSON] LookupSubjectsRequestWire
                    :> MultiVerb 'POST '[JSON] (EnResponses "A page of authorized subjects" LookupSubjectsPageWire) (EnResult LookupSubjectsPageWire)
                :<|> "expand"
                    :> ReqBody '[JSON] ExpandRequestWire
                    :> MultiVerb 'POST '[JSON] (EnResponses "The permission's subject tree" ExpandTreeWire) (EnResult ExpandTreeWire)
                :<|> "watch"
                    :> ReqBody '[JSON] WatchRequestWire
                    :> MultiVerb 'POST '[JSON] (EnResponses "A batch of tuple changes, and a cursor to resume from" WatchResponseWire) (EnResult WatchResponseWire)
                :<|> "schema" :> Get '[JSON] SchemaInfoWire
           )

apiProxy :: Proxy EnAPI
apiProxy = Proxy

server :: (ConsistencyStore Effectful.:> es, TupleStore Effectful.:> es, Error EnError Effectful.:> es, IOE Effectful.:> es) => Env es -> Server EnAPI
server env =
    writeTuplesHandler env
        :<|> deleteTuplesHandler env
        :<|> readRelationshipsHandler env
        :<|> deleteRelationshipsHandler env
        :<|> checkHandler env
        :<|> batchCheckHandler env
        :<|> lookupHandler env
        :<|> lookupSubjectsHandler env
        :<|> expandHandler env
        :<|> watchHandler env
        :<|> schemaHandler env

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

{- | A page of authorized objects, and the snapshot the lookup reads at.

Every page of one traversal carries the same @checkedAt@: the cursor pins the
snapshot, and a continuation reads at the revision its cursor's validated token
names.
-}
data LookupPageWire = LookupPageWire
    { objects :: ![LookupObjectWire]
    , state :: !LookupStateWire
    , checkedAt :: !Text
    }
    deriving stock (Eq, Show)

instance ToJSON LookupPageWire where
    toJSON wire =
        Aeson.object ["objects" .= wire.objects, "state" .= wire.state, "checkedAt" .= wire.checkedAt]
    toEncoding wire =
        pairs ("objects" .= wire.objects <> "state" .= wire.state <> "checkedAt" .= wire.checkedAt)

instance FromJSON LookupPageWire where
    parseJSON = withObject "LookupPageWire" \o ->
        LookupPageWire <$> o .: "objects" <*> o .: "state" <*> o .: "checkedAt"

{- | "Who has access to this object?"

@subjectType@ names one object type and is required, which keeps the traversal bounded
and the answer homogeneous. @deadlineMillis@ is the live time budget, handled exactly as
@\/v1\/lookup@ handles it: omitted means the server default, and a value above the
server's ceiling is clamped rather than rejected.
-}
data LookupSubjectsRequestWire = LookupSubjectsRequestWire
    { consistency :: !ConsistencyWire
    , object :: !ObjectRefWire
    , permission :: !Text
    , subjectType :: !Text
    , context :: !CaveatContextWire
    , limit :: !Int
    , cursor :: !(Maybe Text)
    , deadlineMillis :: !(Maybe Int)
    }
    deriving stock (Eq, Show)

instance ToJSON LookupSubjectsRequestWire where
    toJSON wire =
        Aeson.object
            [ "consistency" .= wire.consistency
            , "object" .= wire.object
            , "permission" .= wire.permission
            , "subjectType" .= wire.subjectType
            , "context" .= wire.context
            , "limit" .= wire.limit
            , "cursor" .= wire.cursor
            , "deadlineMillis" .= wire.deadlineMillis
            ]
    toEncoding wire =
        pairs
            ( "consistency" .= wire.consistency
                <> "object" .= wire.object
                <> "permission" .= wire.permission
                <> "subjectType" .= wire.subjectType
                <> "context" .= wire.context
                <> "limit" .= wire.limit
                <> "cursor" .= wire.cursor
                <> "deadlineMillis" .= wire.deadlineMillis
            )

instance FromJSON LookupSubjectsRequestWire where
    parseJSON = withObject "LookupSubjectsRequestWire" \o ->
        LookupSubjectsRequestWire
            <$> o .: "consistency"
            <*> o .: "object"
            <*> o .: "permission"
            <*> o .: "subjectType"
            <*> o .: "context"
            <*> o .: "limit"
            <*> o .:? "cursor"
            <*> o .:? "deadlineMillis"

{- | One subject holding the permission, and on what terms.

A wildcard grant arrives here as @{"kind": "wildcard", "objectType": "user"}@ — the
'SubjectWildcardWire' constructor 'SubjectWire' already has — so it is distinguishable
from a concrete subject without a new discriminator. It is never expanded into concrete
subjects: the set of users is not en's data.
-}
data LookupSubjectWire = LookupSubjectWire
    { subject :: !SubjectWire
    , decision :: !CheckDecisionWire
    }
    deriving stock (Eq, Show)

instance ToJSON LookupSubjectWire where
    toJSON wire = Aeson.object ["subject" .= wire.subject, "decision" .= wire.decision]
    toEncoding wire = pairs ("subject" .= wire.subject <> "decision" .= wire.decision)

instance FromJSON LookupSubjectWire where
    parseJSON = withObject "LookupSubjectWire" \o ->
        LookupSubjectWire <$> o .: "subject" <*> o .: "decision"

data LookupSubjectsStateWire
    = SubjectsExhaustedWire
    | SubjectsHasMoreWire !Text
    | SubjectsTruncatedWire !Text
    deriving stock (Eq, Show)

instance ToJSON LookupSubjectsStateWire where
    toJSON = \case
        SubjectsExhaustedWire -> Aeson.object ["status" .= ("exhausted" :: Text)]
        SubjectsHasMoreWire cursor -> Aeson.object ["status" .= ("hasMore" :: Text), "cursor" .= cursor]
        SubjectsTruncatedWire cursor -> Aeson.object ["status" .= ("truncated" :: Text), "cursor" .= cursor]
    toEncoding = \case
        SubjectsExhaustedWire -> pairs ("status" .= ("exhausted" :: Text))
        SubjectsHasMoreWire cursor -> pairs ("status" .= ("hasMore" :: Text) <> "cursor" .= cursor)
        SubjectsTruncatedWire cursor -> pairs ("status" .= ("truncated" :: Text) <> "cursor" .= cursor)

instance FromJSON LookupSubjectsStateWire where
    parseJSON = withObject "LookupSubjectsStateWire" \o ->
        o .: "status" >>= \case
            "exhausted" -> pure SubjectsExhaustedWire
            "hasMore" -> SubjectsHasMoreWire <$> o .: "cursor"
            "truncated" -> SubjectsTruncatedWire <$> o .: "cursor"
            other -> unknownVariant "lookup-subjects status" other ["exhausted", "hasMore", "truncated"]

{- | A page of authorized subjects, and the snapshot the lookup reads at.

Every page of one traversal carries the same @checkedAt@: the cursor pins the snapshot,
and a continuation reads at the revision its cursor's validated token names.
-}
data LookupSubjectsPageWire = LookupSubjectsPageWire
    { subjects :: ![LookupSubjectWire]
    , state :: !LookupSubjectsStateWire
    , checkedAt :: !Text
    }
    deriving stock (Eq, Show)

instance ToJSON LookupSubjectsPageWire where
    toJSON wire =
        Aeson.object ["subjects" .= wire.subjects, "state" .= wire.state, "checkedAt" .= wire.checkedAt]
    toEncoding wire =
        pairs ("subjects" .= wire.subjects <> "state" .= wire.state <> "checkedAt" .= wire.checkedAt)

instance FromJSON LookupSubjectsPageWire where
    parseJSON = withObject "LookupSubjectsPageWire" \o ->
        LookupSubjectsPageWire <$> o .: "subjects" <*> o .: "state" <*> o .: "checkedAt"

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

{- | An expand-tree node on the wire.

The @union@, @intersection@, and @exclusion@ kinds say how a node's children combine.
Without them a client cannot tell "all of these" from "any of these" from "these, except
those", which is the whole question an access review asks.

Their spelling follows the @kind@ vocabulary this module already uses rather than the
Haskell constructor names; the @…Wire@ suffix is an internal convention and never reaches
a client. Adding kinds is additive but not free: a client that matches @kind@ exhaustively
will reject a tree containing an operator, so the three arrived together, in one release.
-}
data ExpandNodeWire
    = ExpandSubjectWire !SubjectWire
    | ExpandUsersetWire !ObjectRefWire !Text ![ExpandNodeWire]
    | ExpandCaveatedWire !Text ![ExpandNodeWire]
    | ExpandUnionWire ![ExpandNodeWire]
    | ExpandIntersectionWire ![ExpandNodeWire]
    | -- | Granted children first, subtracted children second.
      ExpandExclusionWire ![ExpandNodeWire] ![ExpandNodeWire]
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
        ExpandUnionWire children ->
            Aeson.object ["kind" .= ("union" :: Text), "children" .= children]
        ExpandIntersectionWire children ->
            Aeson.object ["kind" .= ("intersection" :: Text), "children" .= children]
        ExpandExclusionWire granted subtracted ->
            Aeson.object
                [ "kind" .= ("exclusion" :: Text)
                , "granted" .= granted
                , "subtracted" .= subtracted
                ]
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
        ExpandUnionWire children ->
            pairs ("kind" .= ("union" :: Text) <> "children" .= children)
        ExpandIntersectionWire children ->
            pairs ("kind" .= ("intersection" :: Text) <> "children" .= children)
        ExpandExclusionWire granted subtracted ->
            pairs
                ( "kind" .= ("exclusion" :: Text)
                    <> "granted" .= granted
                    <> "subtracted" .= subtracted
                )

instance FromJSON ExpandNodeWire where
    parseJSON = withObject "ExpandNodeWire" \o ->
        o .: "kind" >>= \case
            "subject" -> ExpandSubjectWire <$> o .: "subject"
            "userset" -> ExpandUsersetWire <$> o .: "object" <*> o .: "relation" <*> o .: "children"
            "caveated" -> ExpandCaveatedWire <$> o .: "caveat" <*> o .: "children"
            "union" -> ExpandUnionWire <$> o .: "children"
            "intersection" -> ExpandIntersectionWire <$> o .: "children"
            "exclusion" -> ExpandExclusionWire <$> o .: "granted" <*> o .: "subtracted"
            other ->
                unknownVariant
                    "expand node kind"
                    other
                    ["subject", "userset", "caveated", "union", "intersection", "exclusion"]

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

-- | The permission's subject tree, and the snapshot it was expanded at.
data ExpandTreeWire = ExpandTreeWire
    { root :: !ObjectRefWire
    , permission :: !Text
    , children :: ![ExpandNodeWire]
    , state :: !ExpandStateWire
    , checkedAt :: !Text
    }
    deriving stock (Eq, Show)

instance ToJSON ExpandTreeWire where
    toJSON wire =
        Aeson.object
            [ "root" .= wire.root
            , "permission" .= wire.permission
            , "children" .= wire.children
            , "state" .= wire.state
            , "checkedAt" .= wire.checkedAt
            ]
    toEncoding wire =
        pairs
            ( "root" .= wire.root
                <> "permission" .= wire.permission
                <> "children" .= wire.children
                <> "state" .= wire.state
                <> "checkedAt" .= wire.checkedAt
            )

instance FromJSON ExpandTreeWire where
    parseJSON = withObject "ExpandTreeWire" \o ->
        ExpandTreeWire
            <$> o .: "root"
            <*> o .: "permission"
            <*> o .: "children"
            <*> o .: "state"
            <*> o .: "checkedAt"

{- | How a filter constrains the subject's relation.

@match@ discriminates. Omitting the whole @subjectRelation@ field means @any@,
which is what SpiceDB's unset @optionalRelation@ means. To name one exact grant
on a concrete subject, send @{"match":"none"}@ — @any@ would also match a userset
over that subject, which is a different grant that can be live at the same time.
-}
data SubjectRelationFilterWire
    = AnySubjectRelationWire
    | NoSubjectRelationWire
    | ExactSubjectRelationWire !Text
    deriving stock (Eq, Show)

instance ToJSON SubjectRelationFilterWire where
    toJSON = \case
        AnySubjectRelationWire -> Aeson.object ["match" .= ("any" :: Text)]
        NoSubjectRelationWire -> Aeson.object ["match" .= ("none" :: Text)]
        ExactSubjectRelationWire relation ->
            Aeson.object ["match" .= ("exact" :: Text), "relation" .= relation]
    toEncoding = \case
        AnySubjectRelationWire -> pairs ("match" .= ("any" :: Text))
        NoSubjectRelationWire -> pairs ("match" .= ("none" :: Text))
        ExactSubjectRelationWire relation ->
            pairs ("match" .= ("exact" :: Text) <> "relation" .= relation)

instance FromJSON SubjectRelationFilterWire where
    parseJSON = withObject "SubjectRelationFilterWire" \o ->
        o .: "match" >>= \case
            "any" -> pure AnySubjectRelationWire
            "none" -> pure NoSubjectRelationWire
            "exact" -> ExactSubjectRelationWire <$> o .: "relation"
            other -> unknownVariant "subject relation match" other ["any", "none", "exact"]

{- | A filter over live tuples. Every field but @objectType@ is optional; an
omitted field matches anything.
-}
data TupleFilterWire = TupleFilterWire
    { objectType :: !Text
    , objectId :: !(Maybe Text)
    , relation :: !(Maybe Text)
    , subjectType :: !(Maybe Text)
    , subjectId :: !(Maybe Text)
    , subjectRelation :: !(Maybe SubjectRelationFilterWire)
    }
    deriving stock (Eq, Show)

{- | An absent constraint is an absent key, not a @null@ one: @null@ would read as
"the subject relation must be null", which 'NoSubjectRelationWire' already says.
-}
instance ToJSON TupleFilterWire where
    toJSON wire =
        Aeson.object $
            ["objectType" .= wire.objectType]
                <> foldMap (\value -> ["objectId" .= value]) wire.objectId
                <> foldMap (\value -> ["relation" .= value]) wire.relation
                <> foldMap (\value -> ["subjectType" .= value]) wire.subjectType
                <> foldMap (\value -> ["subjectId" .= value]) wire.subjectId
                <> foldMap (\value -> ["subjectRelation" .= value]) wire.subjectRelation
    toEncoding wire =
        pairs $
            "objectType" .= wire.objectType
                <> foldMap ("objectId" .=) wire.objectId
                <> foldMap ("relation" .=) wire.relation
                <> foldMap ("subjectType" .=) wire.subjectType
                <> foldMap ("subjectId" .=) wire.subjectId
                <> foldMap ("subjectRelation" .=) wire.subjectRelation

instance FromJSON TupleFilterWire where
    parseJSON = withObject "TupleFilterWire" \o ->
        TupleFilterWire
            <$> o .: "objectType"
            <*> o .:? "objectId"
            <*> o .:? "relation"
            <*> o .:? "subjectType"
            <*> o .:? "subjectId"
            <*> o .:? "subjectRelation"

-- | A fact the write transaction re-verifies before applying any change.
data PreconditionWire
    = TupleMustExistWire !TupleFilterWire
    | TupleMustNotExistWire !TupleFilterWire
    deriving stock (Eq, Show)

instance ToJSON PreconditionWire where
    toJSON = \case
        TupleMustExistWire tupleFilter ->
            Aeson.object ["kind" .= ("mustExist" :: Text), "filter" .= tupleFilter]
        TupleMustNotExistWire tupleFilter ->
            Aeson.object ["kind" .= ("mustNotExist" :: Text), "filter" .= tupleFilter]
    toEncoding = \case
        TupleMustExistWire tupleFilter ->
            pairs ("kind" .= ("mustExist" :: Text) <> "filter" .= tupleFilter)
        TupleMustNotExistWire tupleFilter ->
            pairs ("kind" .= ("mustNotExist" :: Text) <> "filter" .= tupleFilter)

instance FromJSON PreconditionWire where
    parseJSON = withObject "PreconditionWire" \o ->
        o .: "kind" >>= \case
            "mustExist" -> TupleMustExistWire <$> o .: "filter"
            "mustNotExist" -> TupleMustNotExistWire <$> o .: "filter"
            other -> unknownVariant "precondition kind" other ["mustExist", "mustNotExist"]

{- | A write request: @tuples@ are written, @deletes@ are removed first, and every
precondition must hold or the whole request is refused with @412@.

@deletes@ and @preconditions@ are optional, so a body carrying only @tuples@ —
every request written before preconditions existed — decodes and behaves exactly
as it did.
-}
data WriteTuplesRequestWire = WriteTuplesRequestWire
    { tuples :: ![TupleWire]
    , deletes :: !(Maybe [TupleWire])
    , preconditions :: !(Maybe [PreconditionWire])
    }
    deriving stock (Eq, Show)

{- | Absent optional fields are omitted rather than encoded as @null@, so a request
carrying only @tuples@ serializes to exactly the bytes it did before preconditions
existed. The golden test in @en-servant/test/Main.hs@ pins that.
-}
instance ToJSON WriteTuplesRequestWire where
    toJSON wire =
        Aeson.object $
            ["tuples" .= wire.tuples]
                <> foldMap (\value -> ["deletes" .= value]) wire.deletes
                <> foldMap (\value -> ["preconditions" .= value]) wire.preconditions
    toEncoding wire =
        pairs $
            "tuples" .= wire.tuples
                <> foldMap ("deletes" .=) wire.deletes
                <> foldMap ("preconditions" .=) wire.preconditions

instance FromJSON WriteTuplesRequestWire where
    parseJSON = withObject "WriteTuplesRequestWire" \o ->
        WriteTuplesRequestWire <$> o .: "tuples" <*> o .:? "deletes" <*> o .:? "preconditions"

-- | A delete request. @preconditions@ is optional; see 'WriteTuplesRequestWire'.
data DeleteTuplesRequestWire = DeleteTuplesRequestWire
    { tuples :: ![TupleWire]
    , preconditions :: !(Maybe [PreconditionWire])
    }
    deriving stock (Eq, Show)

instance ToJSON DeleteTuplesRequestWire where
    toJSON wire =
        Aeson.object $
            ["tuples" .= wire.tuples] <> foldMap (\value -> ["preconditions" .= value]) wire.preconditions
    toEncoding wire =
        pairs ("tuples" .= wire.tuples <> foldMap ("preconditions" .=) wire.preconditions)

instance FromJSON DeleteTuplesRequestWire where
    parseJSON = withObject "DeleteTuplesRequestWire" \o ->
        DeleteTuplesRequestWire <$> o .: "tuples" <*> o .:? "preconditions"

{- | A filter over stored relationships, for reading and for delete-by-filter.

Every field is optional, but not every combination is legal: the filter must constrain
@objectType@ or @subjectType@, @objectId@ requires @objectType@, and @subjectId@ and a
@subjectRelation@ other than @any@ require @subjectType@. An illegal filter is a @400@.
The rule is not taste — a filter anchored on neither end matches no index and scans the
whole table, so accepting one would let any caller hold the store open.

This is 'TupleFilterWire' with @objectType@ relaxed to optional (so "every grant naming
@user:alice@" is expressible) and @caveatName@ added. The two are separate types because
a precondition's filter is evaluated inside a write transaction, where an unanchored
scan is a lock held over the whole relation, so @objectType@ there is mandatory.
-}
data RelationshipFilterWire = RelationshipFilterWire
    { objectType :: !(Maybe Text)
    , objectId :: !(Maybe Text)
    , relation :: !(Maybe Text)
    , subjectType :: !(Maybe Text)
    , subjectId :: !(Maybe Text)
    , subjectRelation :: !(Maybe SubjectRelationFilterWire)
    , caveatName :: !(Maybe Text)
    }
    deriving stock (Eq, Show)

-- | An absent constraint is an absent key, not a @null@ one. See 'TupleFilterWire'.
instance ToJSON RelationshipFilterWire where
    toJSON wire =
        Aeson.object $
            foldMap (\value -> ["objectType" .= value]) wire.objectType
                <> foldMap (\value -> ["objectId" .= value]) wire.objectId
                <> foldMap (\value -> ["relation" .= value]) wire.relation
                <> foldMap (\value -> ["subjectType" .= value]) wire.subjectType
                <> foldMap (\value -> ["subjectId" .= value]) wire.subjectId
                <> foldMap (\value -> ["subjectRelation" .= value]) wire.subjectRelation
                <> foldMap (\value -> ["caveatName" .= value]) wire.caveatName
    toEncoding wire =
        pairs $
            foldMap ("objectType" .=) wire.objectType
                <> foldMap ("objectId" .=) wire.objectId
                <> foldMap ("relation" .=) wire.relation
                <> foldMap ("subjectType" .=) wire.subjectType
                <> foldMap ("subjectId" .=) wire.subjectId
                <> foldMap ("subjectRelation" .=) wire.subjectRelation
                <> foldMap ("caveatName" .=) wire.caveatName

instance FromJSON RelationshipFilterWire where
    parseJSON = withObject "RelationshipFilterWire" \o ->
        RelationshipFilterWire
            <$> o .:? "objectType"
            <*> o .:? "objectId"
            <*> o .:? "relation"
            <*> o .:? "subjectType"
            <*> o .:? "subjectId"
            <*> o .:? "subjectRelation"
            <*> o .:? "caveatName"

data ReadRelationshipsRequestWire = ReadRelationshipsRequestWire
    { consistency :: !ConsistencyWire
    , filter :: !RelationshipFilterWire
    , limit :: !Int
    , cursor :: !(Maybe Text)
    }
    deriving stock (Eq, Show)

instance ToJSON ReadRelationshipsRequestWire where
    toJSON wire =
        Aeson.object
            [ "consistency" .= wire.consistency
            , "filter" .= wire.filter
            , "limit" .= wire.limit
            , "cursor" .= wire.cursor
            ]
    toEncoding wire =
        pairs
            ( "consistency" .= wire.consistency
                <> "filter" .= wire.filter
                <> "limit" .= wire.limit
                <> "cursor" .= wire.cursor
            )

instance FromJSON ReadRelationshipsRequestWire where
    parseJSON = withObject "ReadRelationshipsRequestWire" \o ->
        ReadRelationshipsRequestWire
            <$> o .: "consistency"
            <*> o .: "filter"
            <*> o .: "limit"
            <*> o .:? "cursor"

{- | Whether a page of relationships is the last one.

Two statuses, not the three 'LookupStateWire' and 'ExpandStateWire' carry: @truncated@
means an evaluation budget ran out mid-page, and a stored-tuple read spends no budget —
it walks an index. A store that somehow reported truncation is reported as @hasMore@,
which resumes from the same cursor and is therefore correct either way.
-}
data RelationshipsStateWire
    = RelationshipsExhaustedWire
    | RelationshipsHasMoreWire !Text
    deriving stock (Eq, Show)

instance ToJSON RelationshipsStateWire where
    toJSON = \case
        RelationshipsExhaustedWire -> Aeson.object ["status" .= ("exhausted" :: Text)]
        RelationshipsHasMoreWire cursor -> Aeson.object ["status" .= ("hasMore" :: Text), "cursor" .= cursor]
    toEncoding = \case
        RelationshipsExhaustedWire -> pairs ("status" .= ("exhausted" :: Text))
        RelationshipsHasMoreWire cursor -> pairs ("status" .= ("hasMore" :: Text) <> "cursor" .= cursor)

instance FromJSON RelationshipsStateWire where
    parseJSON = withObject "RelationshipsStateWire" \o ->
        o .: "status" >>= \case
            "exhausted" -> pure RelationshipsExhaustedWire
            "hasMore" -> RelationshipsHasMoreWire <$> o .: "cursor"
            other -> unknownVariant "relationships status" other ["exhausted", "hasMore"]

-- | A page of stored relationships, and the snapshot they were read at.
data ReadRelationshipsResponseWire = ReadRelationshipsResponseWire
    { relationships :: ![TupleWire]
    , state :: !RelationshipsStateWire
    , checkedAt :: !Text
    }
    deriving stock (Eq, Show)

instance ToJSON ReadRelationshipsResponseWire where
    toJSON wire =
        Aeson.object
            [ "relationships" .= wire.relationships
            , "state" .= wire.state
            , "checkedAt" .= wire.checkedAt
            ]
    toEncoding wire =
        pairs
            ( "relationships" .= wire.relationships
                <> "state" .= wire.state
                <> "checkedAt" .= wire.checkedAt
            )

instance FromJSON ReadRelationshipsResponseWire where
    parseJSON = withObject "ReadRelationshipsResponseWire" \o ->
        ReadRelationshipsResponseWire <$> o .: "relationships" <*> o .: "state" <*> o .: "checkedAt"

{- | A delete-by-filter request. @dryRun@ is mandatory and has no default.

This is the most destructive operation in the API, and a defaulted flag is one a caller
can omit by accident. Requiring it means intent is always stated: a body missing @dryRun@
is a @400@, not a deletion.
-}
data DeleteRelationshipsRequestWire = DeleteRelationshipsRequestWire
    { filter :: !RelationshipFilterWire
    , dryRun :: !Bool
    }
    deriving stock (Eq, Show)

instance ToJSON DeleteRelationshipsRequestWire where
    toJSON wire = Aeson.object ["filter" .= wire.filter, "dryRun" .= wire.dryRun]
    toEncoding wire = pairs ("filter" .= wire.filter <> "dryRun" .= wire.dryRun)

instance FromJSON DeleteRelationshipsRequestWire where
    parseJSON = withObject "DeleteRelationshipsRequestWire" \o ->
        DeleteRelationshipsRequestWire <$> o .: "filter" <*> o .: "dryRun"

{- | @count@ is how many grants a real deletion retired, or — for a dry run — how many it
would have. @token@ is present exactly when @dryRun@ was false: a dry run writes nothing,
so it has no revision to name. A caller that deleted can pass the token straight back as
@atLeastAsFresh@ and observe the revocation.
-}
data DeleteRelationshipsResponseWire = DeleteRelationshipsResponseWire
    { dryRun :: !Bool
    , count :: !Int64
    , token :: !(Maybe Text)
    }
    deriving stock (Eq, Show)

instance ToJSON DeleteRelationshipsResponseWire where
    toJSON wire =
        Aeson.object ["dryRun" .= wire.dryRun, "count" .= wire.count, "token" .= wire.token]
    toEncoding wire =
        pairs ("dryRun" .= wire.dryRun <> "count" .= wire.count <> "token" .= wire.token)

instance FromJSON DeleteRelationshipsResponseWire where
    parseJSON = withObject "DeleteRelationshipsResponseWire" \o ->
        DeleteRelationshipsResponseWire <$> o .: "dryRun" <*> o .: "count" <*> o .:? "token"

{- | One poll of the changelog feed.

Exactly one start position. @cursor@ resumes a subscription; @startToken@ opens one at the
snapshot an ordinary consistency token pins ("everything since my write"); both absent
starts one at the current head, returning no changes and the cursor to poll with next.
Both present is a @400@ — a caller that supplied two start positions does not know where it
wants to start, and picking one for it would silently skip or replay history.

There is no @consistency@ field, and its absence is the contract. A poll's window is fixed
by its start position and the store's head; a resuming poll reads the window its cursor
names and nothing else. A caller able to ask for a fresher snapshot mid-drain could span two
of them and receive a batch with gaps.

@filter@ scopes the subscription. It is 'RelationshipFilterWire', unchanged, so "watch every
grant naming @user:alice@" and "read every grant naming @user:alice@" are the same filter.
-}
data WatchRequestWire = WatchRequestWire
    { cursor :: !(Maybe Text)
    , startToken :: !(Maybe Text)
    , filter :: !(Maybe RelationshipFilterWire)
    , limit :: !Int
    }
    deriving stock (Eq, Show)

instance ToJSON WatchRequestWire where
    toJSON wire =
        Aeson.object
            [ "cursor" .= wire.cursor
            , "startToken" .= wire.startToken
            , "filter" .= wire.filter
            , "limit" .= wire.limit
            ]
    toEncoding wire =
        pairs
            ( "cursor" .= wire.cursor
                <> "startToken" .= wire.startToken
                <> "filter" .= wire.filter
                <> "limit" .= wire.limit
            )

instance FromJSON WatchRequestWire where
    parseJSON = withObject "WatchRequestWire" \o ->
        WatchRequestWire
            <$> o .:? "cursor"
            <*> o .:? "startToken"
            <*> o .:? "filter"
            <*> o .: "limit"

{- | What happened to a tuple: it became live, or it stopped being live.

A bare string rather than the discriminated object the other sum types carry, because it has
no variant-specific fields to discriminate. It is itself the @kind@ discriminator of
'TupleChangeWire'.
-}
data ChangeKindWire
    = TouchWire
    | DeleteWire
    deriving stock (Eq, Show)

instance ToJSON ChangeKindWire where
    toJSON = \case
        TouchWire -> Aeson.String "touch"
        DeleteWire -> Aeson.String "delete"
    toEncoding = \case
        TouchWire -> toEncoding ("touch" :: Text)
        DeleteWire -> toEncoding ("delete" :: Text)

instance FromJSON ChangeKindWire where
    parseJSON = Aeson.withText "ChangeKindWire" \case
        "touch" -> pure TouchWire
        "delete" -> pure DeleteWire
        other -> unknownVariant "change kind" other ["touch", "delete"]

data TupleChangeWire = TupleChangeWire
    { kind :: !ChangeKindWire
    , tuple :: !TupleWire
    }
    deriving stock (Eq, Show)

instance ToJSON TupleChangeWire where
    toJSON wire = Aeson.object ["kind" .= wire.kind, "tuple" .= wire.tuple]
    toEncoding wire = pairs ("kind" .= wire.kind <> "tuple" .= wire.tuple)

instance FromJSON TupleChangeWire where
    parseJSON = withObject "TupleChangeWire" \o ->
        TupleChangeWire <$> o .: "kind" <*> o .: "tuple"

{- | A batch of changes, the cursor that resumes after them, and the snapshot they end at.

@changes@ carries no order. It is the set difference of the live tuple set across the
batch's window: transaction ids are assigned at transaction start and visibility flips at
commit, so the store cannot say which of two changes happened first, and pretending
otherwise would be a promise it could not keep. Order holds only /between/ batches.

@cursor@ is always present, including on an empty batch — a caught-up consumer must still be
able to poll again. It is opaque: the only thing to do with it is send it back.

@changes@ can be empty while the feed still has more to give, because a grant written and
retired inside one window contributes no event yet still consumes a page. A drain therefore
ends when a poll's @cursor@ stops advancing, not at the first empty page.
-}
data WatchResponseWire = WatchResponseWire
    { changes :: ![TupleChangeWire]
    , cursor :: !Text
    , checkedAt :: !Text
    }
    deriving stock (Eq, Show)

instance ToJSON WatchResponseWire where
    toJSON wire =
        Aeson.object
            [ "changes" .= wire.changes
            , "cursor" .= wire.cursor
            , "checkedAt" .= wire.checkedAt
            ]
    toEncoding wire =
        pairs
            ( "changes" .= wire.changes
                <> "cursor" .= wire.cursor
                <> "checkedAt" .= wire.checkedAt
            )

instance FromJSON WatchResponseWire where
    parseJSON = withObject "WatchResponseWire" \o ->
        WatchResponseWire <$> o .: "changes" <*> o .: "cursor" <*> o .: "checkedAt"

{- | The authorization model the server is currently serving.

@source@ is the verbatim text the operator wrote, not a rendering of the compiled model:
there is no @Schema -> Text@ serializer for the loadable DSL, and the text is in any case
what a candidate schema should be diffed against. @origin@ is the file path it was read
from, or @builtin-demo@ when @EN_SCHEMA_PATH@ is unset. @loadedAt@ moves on every reload
that swaps the model.

This response carries no @checkedAt@ (see 'CheckResponseWire'). That field names the tuple
store snapshot a read was evaluated at, and this is not a read of the tuple store — it is
server metadata, held in memory, describing no revision. @loadedAt@ is the analogous
freshness handle, and it answers the only question a caller can ask of it.
-}
data SchemaInfoWire = SchemaInfoWire
    { source :: !Text
    , hash :: !Text
    , origin :: !Text
    , loadedAt :: !UTCTime
    }
    deriving stock (Eq, Show)

instance ToJSON SchemaInfoWire where
    toJSON wire =
        Aeson.object
            [ "source" .= wire.source
            , "hash" .= wire.hash
            , "origin" .= wire.origin
            , "loadedAt" .= wire.loadedAt
            ]
    toEncoding wire =
        pairs
            ( "source" .= wire.source
                <> "hash" .= wire.hash
                <> "origin" .= wire.origin
                <> "loadedAt" .= wire.loadedAt
            )

instance FromJSON SchemaInfoWire where
    parseJSON = withObject "SchemaInfoWire" \o ->
        SchemaInfoWire <$> o .: "source" <*> o .: "hash" <*> o .: "origin" <*> o .: "loadedAt"

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
    active <- activeSchema env
    writes <- traverseOrInvalid tupleFromWire request.tuples
    deletes <- traverseOrInvalid tupleFromWire (fromMaybe [] request.deletes)
    preconditions <- traverseOrInvalid preconditionFromWire (fromMaybe [] request.preconditions)
    token <- engine env active (applyTupleWrites TupleWriteRequest{preconditions, writes, deletes})
    pure (tokenToWire token)

deleteTuplesHandler :: (TupleStore Effectful.:> es) => Env es -> DeleteTuplesRequestWire -> Handler (EnResult WriteTuplesResponseWire)
deleteTuplesHandler env request = enHandler do
    active <- activeSchema env
    deletes <- traverseOrInvalid tupleFromWire request.tuples
    preconditions <- traverseOrInvalid preconditionFromWire (fromMaybe [] request.preconditions)
    token <- engine env active (applyTupleWrites TupleWriteRequest{preconditions, writes = [], deletes})
    pure (tokenToWire token)

readRelationshipsHandler ::
    (ConsistencyStore Effectful.:> es, TupleStore Effectful.:> es) =>
    Env es ->
    ReadRelationshipsRequestWire ->
    Handler (EnResult ReadRelationshipsResponseWire)
readRelationshipsHandler env request = enHandler do
    active <- activeSchema env
    consistency <- orInvalid (consistencyFromWire request.consistency)
    relationshipFilter <- orInvalid (relationshipFilterFromWire request.filter)
    limit <- orInvalid (positiveLimit request.limit)
    (checkedAt, page) <-
        engine env active do
            ResolvedConsistency{revision} <- resolveConsistency consistency
            checkedAt <- mintToken revision
            page <- readRelationships revision relationshipFilter limit (StoreCursor <$> request.cursor)
            pure (checkedAt, page)
    pure (relationshipsPageToWire checkedAt page)

{- | Dry-run and deletion are one endpoint because they must ask the store the same
question. Splitting them into @\/count@ and @\/delete@ would invite a caller to count
against a snapshot and delete against a later one, and be surprised by the difference.

The dry run resolves 'FullyConsistent' rather than the caller's consistency: a count read
from a stale replica is not a preview of what a delete — which always acts on live state —
is about to do.
-}
deleteRelationshipsHandler ::
    (ConsistencyStore Effectful.:> es, TupleStore Effectful.:> es) =>
    Env es ->
    DeleteRelationshipsRequestWire ->
    Handler (EnResult DeleteRelationshipsResponseWire)
deleteRelationshipsHandler env request = enHandler do
    active <- activeSchema env
    relationshipFilter <- orInvalid (relationshipFilterFromWire request.filter)
    if request.dryRun
        then do
            count <-
                engine env active do
                    ResolvedConsistency{revision} <- resolveConsistency FullyConsistent
                    countRelationships revision relationshipFilter
            pure DeleteRelationshipsResponseWire{dryRun = True, count, token = Nothing}
        else do
            (count, ConsistencyToken token) <- engine env active (deleteRelationships relationshipFilter)
            pure DeleteRelationshipsResponseWire{dryRun = False, count, token = Just token}

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

lookupHandler :: (IOE Effectful.:> es) => Env es -> LookupRequestWire -> Handler (EnResult LookupPageWire)
lookupHandler env request = enHandler do
    active <- activeSchema env
    consistency <- orInvalid (consistencyFromWire request.consistency)
    context <- orInvalid (contextFromWire request.context)
    subject <- orInvalid (subjectFromWire request.subject)
    deadline <- lift (lookupDeadline env request.deadlineMillis)
    page <-
        engine
            env
            active
            ( env.lookupWithDeadlineOperation
                deadline
                active.graph
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

{- | "Who can view this?" — the flat, cursored subject set.

Unlike @\/v1\/lookup@, this validates @limit@. A zero limit returns an empty page whose
cursor equals the caller's own, so a drain loop over it never terminates and never
advances; the same reason 'positiveLimit' guards the relationship read.
-}
lookupSubjectsHandler :: (IOE Effectful.:> es) => Env es -> LookupSubjectsRequestWire -> Handler (EnResult LookupSubjectsPageWire)
lookupSubjectsHandler env request = enHandler do
    active <- activeSchema env
    consistency <- orInvalid (consistencyFromWire request.consistency)
    context <- orInvalid (contextFromWire request.context)
    object <- orInvalid (objectRefFromWire request.object)
    permission <- orInvalid (nonEmptyRelation "permission" request.permission)
    subjectType <- orInvalid (nonEmptyObjectType "subjectType" request.subjectType)
    limit <- orInvalid (positiveLimit request.limit)
    deadline <- lift (lookupDeadline env request.deadlineMillis)
    page <-
        engine
            env
            active
            ( env.lookupSubjectsWithDeadlineOperation
                deadline
                active.graph
                consistency
                LookupSubjects.LookupSubjectsRequest
                    { object
                    , permission
                    , subjectType
                    , context
                    , limit
                    , cursor = LookupSubjects.LookupSubjectsCursor <$> request.cursor
                    }
            )
    pure (lookupSubjectsPageToWire page)

{- | The time budget for one lookup, measured on the monotonic clock.

The server owns the ceiling. An unbounded client-supplied budget is a hostage problem:
@deadlineMillis: 86400000@ would pin a worker for a day. A request above
'deadlineMaxMillis' is clamped down to it rather than rejected, so a client asking for
more time than it can have still gets an answer.
-}
lookupDeadline :: (IOE Effectful.:> es) => Env es' -> Maybe Int -> Handler (Lookup.Deadline (Eff es))
lookupDeadline env maybeDeadlineMillis = do
    startedAt <- liftIO getMonotonicTimeNSec
    let requestedMillis = fromMaybe env.deadlineDefaultMillis maybeDeadlineMillis
        budgetMillis = min env.deadlineMaxMillis (max 0 requestedMillis)
        budgetNs :: Word64
        budgetNs = fromIntegral budgetMillis * 1000000
    pure $
        Lookup.Deadline $ do
            now <- Effectful.liftIO getMonotonicTimeNSec
            pure (now - startedAt <= budgetNs)

expandHandler :: (ConsistencyStore Effectful.:> es, TupleStore Effectful.:> es, Error EnError Effectful.:> es) => Env es -> ExpandRequestWire -> Handler (EnResult ExpandTreeWire)
expandHandler env request = enHandler do
    active <- activeSchema env
    consistency <- orInvalid (consistencyFromWire request.consistency)
    context <- orInvalid (contextFromWire request.context)
    object <- orInvalid (objectRefFromWire request.object)
    tree <-
        engine
            env
            active
            ( Expand.expand
                active.graph
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

{- | One poll of the changelog feed.

@limit@ is clamped to 'maxBatchSize' rather than rejected above it, following the deadline's
precedent: asking for as much as the server will give is reasonable, and the server decides
how much that is. It must still be positive — a zero limit returns an empty page whose
cursor equals the caller's own, so a drain loop over it never terminates and never advances.
-}
watchHandler :: Env es -> WatchRequestWire -> Handler (EnResult WatchResponseWire)
watchHandler env request = enHandler do
    active <- activeSchema env
    start <- orInvalid (watchStartFromWire request.cursor request.startToken)
    relationshipFilter <- orInvalid (traverse relationshipFilterFromWire request.filter)
    limit <- orInvalid (positiveLimit request.limit)
    batch <- engine env active (env.watchOperation start relationshipFilter (min env.maxBatchSize limit))
    pure (watchBatchToWire batch)

{- | The model this server is serving, right now.

Not an 'EnResult': it reads one 'ActiveSchema' out of memory and cannot fail, so it has no
fault to return into a response alternative. Everything on 'EnAPI' that can fail speaks the
error envelope; this operation cannot.
-}
schemaHandler :: Env es -> Handler SchemaInfoWire
schemaHandler env = do
    active <- liftIO env.readActiveSchema
    let SchemaHash hash = active.graph.hash
    pure
        SchemaInfoWire
            { source = active.source
            , hash
            , origin = active.origin
            , loadedAt = active.loadedAt
            }

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

preconditionFromWire :: PreconditionWire -> Either Text Precondition
preconditionFromWire = \case
    TupleMustExistWire tupleFilter -> TupleMustExist <$> tupleFilterFromWire tupleFilter
    TupleMustNotExistWire tupleFilter -> TupleMustNotExist <$> tupleFilterFromWire tupleFilter

{- | An empty string is rejected rather than treated as an absent constraint: a
filter whose @objectId@ is @""@ matches nothing, and silently accepting it would
make a must-exist precondition fail for a reason the caller cannot see.
-}
tupleFilterFromWire :: TupleFilterWire -> Either Text TupleFilter
tupleFilterFromWire tupleFilter
    | Text.null tupleFilter.objectType = Left "filter objectType must not be empty"
    | otherwise =
        TupleFilter (ObjectType tupleFilter.objectType)
            <$> traverse (nonEmpty "filter objectId") tupleFilter.objectId
            <*> traverse (fmap RelationName . nonEmpty "filter relation") tupleFilter.relation
            <*> traverse (fmap ObjectType . nonEmpty "filter subjectType") tupleFilter.subjectType
            <*> traverse (nonEmpty "filter subjectId") tupleFilter.subjectId
            <*> subjectRelationFromWire (fromMaybe AnySubjectRelationWire tupleFilter.subjectRelation)
  where
    nonEmpty label value
        | Text.null value = Left (label <> " must not be empty")
        | otherwise = Right value

{- | Convert and then validate: a filter that decodes but does not anchor is still a
client fault, and 'validateRelationshipFilter' owns the grammar. The two steps are one
function so no handler can perform the first and forget the second.

As in 'tupleFilterFromWire', an empty string is rejected rather than read as an absent
constraint: @objectId: ""@ matches nothing, and silently widening it to "any object" would
turn a narrow read into a table scan, or a narrow delete into a mass revocation.
-}
relationshipFilterFromWire :: RelationshipFilterWire -> Either Text RelationshipFilter
relationshipFilterFromWire wire = do
    converted <-
        RelationshipFilter
            <$> traverse (fmap ObjectType . nonEmpty "filter objectType") wire.objectType
            <*> traverse (nonEmpty "filter objectId") wire.objectId
            <*> traverse (fmap RelationName . nonEmpty "filter relation") wire.relation
            <*> traverse (fmap ObjectType . nonEmpty "filter subjectType") wire.subjectType
            <*> traverse (nonEmpty "filter subjectId") wire.subjectId
            <*> subjectRelationFromWire (fromMaybe AnySubjectRelationWire wire.subjectRelation)
            <*> traverse (fmap CaveatName . nonEmpty "filter caveatName") wire.caveatName
    validateRelationshipFilter converted
  where
    nonEmpty label value
        | Text.null value = Left (label <> " must not be empty")
        | otherwise = Right value

{- | A page limit must be positive. Zero would return an empty page whose cursor equals
the caller's own, so a drain loop over it never terminates and never advances.
-}
positiveLimit :: Int -> Either Text Int
positiveLimit limit
    | limit <= 0 = Left "limit must be positive"
    | otherwise = Right limit

nonEmptyRelation :: Text -> Text -> Either Text RelationName
nonEmptyRelation label value
    | Text.null value = Left (label <> " must not be empty")
    | otherwise = Right (RelationName value)

nonEmptyObjectType :: Text -> Text -> Either Text ObjectType
nonEmptyObjectType label value
    | Text.null value = Left (label <> " must not be empty")
    | otherwise = Right (ObjectType value)

relationshipsPageToWire :: ConsistencyToken -> TuplePage -> ReadRelationshipsResponseWire
relationshipsPageToWire (ConsistencyToken checkedAt) TuplePage{rows, state} =
    ReadRelationshipsResponseWire
        { relationships = tupleToWire . (.tuple) <$> rows
        , state = relationshipsStateToWire state
        , checkedAt
        }

{- | Exactly one start position, or a client fault naming which rule was broken.

An empty string is rejected rather than read as an absent field, as everywhere else in this
module: @cursor: ""@ is a cursor this store never issued, and silently starting the feed
from now in its place would tell a resuming consumer it was caught up while a window's worth
of revocations went unread.
-}
watchStartFromWire :: Maybe Text -> Maybe Text -> Either Text Watch.WatchStart
watchStartFromWire maybeCursor maybeStartToken =
    case (maybeCursor, maybeStartToken) of
        (Just _, Just _) -> Left "watch takes cursor or startToken, not both"
        (Just cursor, Nothing)
            | Text.null cursor -> Left "cursor must not be empty"
            | otherwise -> Right (Watch.StartFromCursor cursor)
        (Nothing, Just startToken)
            | Text.null startToken -> Left "startToken must not be empty"
            | otherwise -> Right (Watch.StartFromToken startToken)
        (Nothing, Nothing) -> Right Watch.StartFromNow

watchBatchToWire :: Watch.WatchBatch -> WatchResponseWire
watchBatchToWire Watch.WatchBatch{changes, cursor, checkedAt = ConsistencyToken checkedAt} =
    WatchResponseWire{changes = tupleChangeToWire <$> changes, cursor, checkedAt}

tupleChangeToWire :: TupleChange -> TupleChangeWire
tupleChangeToWire TupleChange{kind, tuple} =
    TupleChangeWire{kind = changeKindToWire kind, tuple = tupleToWire tuple}

changeKindToWire :: ChangeKind -> ChangeKindWire
changeKindToWire = \case
    ChangeTouch -> TouchWire
    ChangeDelete -> DeleteWire

relationshipsStateToWire :: PageState -> RelationshipsStateWire
relationshipsStateToWire =
    \case
        Exhausted -> RelationshipsExhaustedWire
        HasMore (StoreCursor cursor) -> RelationshipsHasMoreWire cursor
        -- See 'RelationshipsStateWire': a stored-tuple read spends no budget, so it
        -- cannot truncate. Resuming from the cursor is right regardless.
        Truncated (StoreCursor cursor) -> RelationshipsHasMoreWire cursor

subjectRelationFromWire :: SubjectRelationFilterWire -> Either Text SubjectRelationFilter
subjectRelationFromWire = \case
    AnySubjectRelationWire -> Right AnySubjectRelation
    NoSubjectRelationWire -> Right NoSubjectRelation
    ExactSubjectRelationWire relation
        | Text.null relation -> Left "filter subject relation must not be empty"
        | otherwise -> Right (ExactSubjectRelation (RelationName relation))

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
lookupPageToWire Lookup.LookupPage{objects, state, checkedAt = ConsistencyToken checkedAt} =
    LookupPageWire
        { objects = lookupObjectToWire <$> objects
        , state = lookupStateToWire state
        , checkedAt
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

lookupSubjectsPageToWire :: LookupSubjects.LookupSubjectsPage -> LookupSubjectsPageWire
lookupSubjectsPageToWire LookupSubjects.LookupSubjectsPage{subjects, state, checkedAt = ConsistencyToken checkedAt} =
    LookupSubjectsPageWire
        { subjects = lookupSubjectToWire <$> subjects
        , state = lookupSubjectsStateToWire state
        , checkedAt
        }

lookupSubjectToWire :: LookupSubjects.LookupSubject -> LookupSubjectWire
lookupSubjectToWire LookupSubjects.LookupSubject{subject, decision} =
    LookupSubjectWire{subject = subjectToWire subject, decision = decisionToWire decision}

lookupSubjectsStateToWire :: LookupSubjects.LookupSubjectsState -> LookupSubjectsStateWire
lookupSubjectsStateToWire =
    \case
        LookupSubjects.SubjectsExhausted -> SubjectsExhaustedWire
        LookupSubjects.SubjectsHasMore (LookupSubjects.LookupSubjectsCursor cursor) -> SubjectsHasMoreWire cursor
        LookupSubjects.SubjectsTruncated (LookupSubjects.LookupSubjectsCursor cursor) -> SubjectsTruncatedWire cursor

expandTreeToWire :: Expand.ExpandTree -> ExpandTreeWire
expandTreeToWire Expand.ExpandTree{root, permission = RelationName permission, children, state, checkedAt = ConsistencyToken checkedAt} =
    ExpandTreeWire
        { root = objectRefToWire root
        , permission
        , children = expandNodeToWire <$> children
        , state = expandStateToWire state
        , checkedAt
        }

expandNodeToWire :: Expand.ExpandNode -> ExpandNodeWire
expandNodeToWire =
    \case
        Expand.ExpandSubject subject _row -> ExpandSubjectWire (subjectToWire subject)
        Expand.ExpandUserset object (RelationName relation) children ->
            ExpandUsersetWire (objectRefToWire object) relation (expandNodeToWire <$> children)
        Expand.ExpandCaveated (CaveatName caveat) children ->
            ExpandCaveatedWire caveat (expandNodeToWire <$> children)
        Expand.ExpandUnion children -> ExpandUnionWire (expandNodeToWire <$> children)
        Expand.ExpandIntersection children -> ExpandIntersectionWire (expandNodeToWire <$> children)
        Expand.ExpandExclusion granted subtracted ->
            ExpandExclusionWire (expandNodeToWire <$> granted) (expandNodeToWire <$> subtracted)

expandStateToWire :: Expand.ExpandState -> ExpandStateWire
expandStateToWire =
    \case
        Expand.ExpandExhausted -> ExpandExhaustedWire
        Expand.ExpandHasMore (Expand.ExpandCursor cursor) -> ExpandHasMoreWire cursor
        Expand.ExpandTruncated (Expand.ExpandCursor cursor) -> ExpandTruncatedWire cursor

-- | Run an engine action, surfacing an 'En.Error.EnError' as an 'EnFault'.

{- | Run an engine action under the request's schema snapshot.

Every handler takes the snapshot once, at its start, and threads that one value through
both its evaluation ('ActiveSchema.graph') and its store interpreters (which build their
'En.Postgres.Revision.ConsistencyConfig' from @active.graph.hash@). A handler that called
'activeSchema' twice, or that passed one snapshot to 'engine' while reading a graph from
another, could straddle a schema reload and mint a token under a model it did not evaluate.
-}
engine :: Env es -> ActiveSchema -> Eff es a -> ExceptT EnFault Handler a
engine env active action =
    ExceptT (runEngineEither env active action)

-- | The schema this request is served under. Called once per handler. See 'engine'.
activeSchema :: Env es -> ExceptT EnFault Handler ActiveSchema
activeSchema env =
    liftIO env.readActiveSchema

-- | A wire-to-engine conversion failure is a client fault, not an engine error.
orInvalid :: Either Text a -> ExceptT EnFault Handler a
orInvalid =
    either (throwE . invalidRequest) pure

traverseOrInvalid :: (a -> Either Text b) -> [a] -> ExceptT EnFault Handler [b]
traverseOrInvalid convert values =
    orInvalid (traverse convert values)
