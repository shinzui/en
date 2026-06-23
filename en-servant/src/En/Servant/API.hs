{-# LANGUAGE TypeOperators #-}

-- | The en HTTP API as a Servant API type plus server handlers.
module En.Servant.API (
    EnAPI,
    apiProxy,
    EnServer (..),
    server,
    app,
    ObjectRefWire (..),
    SubjectWire (..),
    TupleWire (..),
    TupleCaveatWire (..),
    CaveatValueWire (..),
    ConsistencyWire (..),
    CaveatContextWire (..),
    CheckRequestWire (..),
    CheckResponseWire (..),
    LookupRequestWire (..),
    LookupObjectWire (..),
    LookupPageWire (..),
    ExpandRequestWire (..),
    ExpandNodeWire (..),
    ExpandTreeWire (..),
    WriteTuplesRequestWire (..),
    WriteTuplesResponseWire (..),
    DeleteTuplesRequestWire (..),
    ErrorWire (..),
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
import Data.Aeson (FromJSON, ToJSON, encode)
import Data.Map.Strict (Map)
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Text.Encoding qualified as Text
import Data.Time (UTCTime)
import GHC.Generics (Generic)
import Servant (
    Application,
    Delete,
    Handler,
    JSON,
    Post,
    Proxy (..),
    ReqBody,
    Server,
    ServerError (..),
    err400,
    err500,
    serve,
    throwError,
    type (:<|>) (..),
    type (:>),
 )

import En.Check (CaveatObligation (..), CheckDecision (..), check)
import En.Effect.ConsistencyStore (ConsistencyStore)
import En.Effect.TupleStore (TupleStore (..))
import En.Error (EnError)
import En.Expand qualified as Expand
import En.Lookup qualified as Lookup
import En.Reachability (ReachabilityGraph)
import En.Revision (Consistency (..), ConsistencyToken (..))
import En.Schema (CaveatName (..), ObjectType (..), RelationName (..))
import En.Tuple (
    CaveatContext (..),
    CaveatPayload (..),
    CaveatValue (..),
    ObjectRef (..),
    Subject (..),
    Tuple (..),
    TupleCaveat (..),
 )

type EnAPI =
    "tuples" :> ReqBody '[JSON] WriteTuplesRequestWire :> Post '[JSON] WriteTuplesResponseWire
        :<|> "tuples" :> ReqBody '[JSON] DeleteTuplesRequestWire :> Delete '[JSON] WriteTuplesResponseWire
        :<|> "check" :> ReqBody '[JSON] CheckRequestWire :> Post '[JSON] CheckResponseWire
        :<|> "lookup" :> ReqBody '[JSON] LookupRequestWire :> Post '[JSON] LookupPageWire
        :<|> "expand" :> ReqBody '[JSON] ExpandRequestWire :> Post '[JSON] ExpandTreeWire

apiProxy :: Proxy EnAPI
apiProxy = Proxy

data EnServer = EnServer
    { consistencyStore :: !(ConsistencyStore IO)
    , tupleStore :: !(TupleStore IO)
    , graph :: !ReachabilityGraph
    }

server :: EnServer -> Server EnAPI
server env =
    writeTuplesHandler env
        :<|> deleteTuplesHandler env
        :<|> checkHandler env
        :<|> lookupHandler env
        :<|> expandHandler env

app :: EnServer -> Application
app =
    serve apiProxy . server

data ObjectRefWire = ObjectRefWire
    { objectType :: !Text
    , objectId :: !Text
    }
    deriving stock (Eq, Show, Generic)
    deriving anyclass (FromJSON, ToJSON)

data SubjectWire
    = SubjectIdWire !ObjectRefWire
    | SubjectSetWire !ObjectRefWire !Text
    | SubjectWildcardWire !Text
    deriving stock (Eq, Show, Generic)
    deriving anyclass (FromJSON, ToJSON)

data CaveatValueWire
    = ValueTextWire !Text
    | ValueBoolWire !Bool
    | ValueIntegerWire !Integer
    | ValueTimestampWire !UTCTime
    | ValueEnumWire !Text
    deriving stock (Eq, Show, Generic)
    deriving anyclass (FromJSON, ToJSON)

newtype CaveatPayloadWire = CaveatPayloadWire
    { values :: Map Text CaveatValueWire
    }
    deriving stock (Eq, Show, Generic)
    deriving anyclass (FromJSON, ToJSON)

newtype CaveatContextWire = CaveatContextWire
    { values :: Map Text CaveatValueWire
    }
    deriving stock (Eq, Show, Generic)
    deriving anyclass (FromJSON, ToJSON)

data TupleCaveatWire = TupleCaveatWire
    { name :: !Text
    , payload :: !CaveatPayloadWire
    }
    deriving stock (Eq, Show, Generic)
    deriving anyclass (FromJSON, ToJSON)

data TupleWire = TupleWire
    { object :: !ObjectRefWire
    , relation :: !Text
    , subject :: !SubjectWire
    , caveat :: !(Maybe TupleCaveatWire)
    }
    deriving stock (Eq, Show, Generic)
    deriving anyclass (FromJSON, ToJSON)

data ConsistencyWire
    = MinimizeLatencyWire
    | FullyConsistentWire
    | AtLeastAsFreshWire !Text
    | AtExactSnapshotWire !Text
    deriving stock (Eq, Show, Generic)
    deriving anyclass (FromJSON, ToJSON)

data CheckRequestWire = CheckRequestWire
    { consistency :: !ConsistencyWire
    , context :: !CaveatContextWire
    , subject :: !SubjectWire
    , permission :: !Text
    , object :: !ObjectRefWire
    }
    deriving stock (Eq, Show, Generic)
    deriving anyclass (FromJSON, ToJSON)

data CheckDecisionWire
    = AllowedWire
    | DeniedWire
    | ConditionalWire ![CaveatObligationWire]
    deriving stock (Eq, Show, Generic)
    deriving anyclass (FromJSON, ToJSON)

data CaveatObligationWire = CaveatObligationWire
    { caveat :: !Text
    , missingContext :: ![Text]
    }
    deriving stock (Eq, Show, Generic)
    deriving anyclass (FromJSON, ToJSON)

newtype CheckResponseWire = CheckResponseWire
    { decision :: CheckDecisionWire
    }
    deriving stock (Eq, Show, Generic)
    deriving anyclass (FromJSON, ToJSON)

data LookupRequestWire = LookupRequestWire
    { consistency :: !ConsistencyWire
    , subject :: !SubjectWire
    , permission :: !Text
    , objectType :: !Text
    , context :: !CaveatContextWire
    , limit :: !Int
    , cursor :: !(Maybe Text)
    }
    deriving stock (Eq, Show, Generic)
    deriving anyclass (FromJSON, ToJSON)

data LookupObjectWire = LookupObjectWire
    { object :: !ObjectRefWire
    , decision :: !CheckDecisionWire
    }
    deriving stock (Eq, Show, Generic)
    deriving anyclass (FromJSON, ToJSON)

data LookupStateWire
    = LookupExhaustedWire
    | LookupHasMoreWire !Text
    | LookupTruncatedWire !Text
    deriving stock (Eq, Show, Generic)
    deriving anyclass (FromJSON, ToJSON)

data LookupPageWire = LookupPageWire
    { objects :: ![LookupObjectWire]
    , state :: !LookupStateWire
    }
    deriving stock (Eq, Show, Generic)
    deriving anyclass (FromJSON, ToJSON)

data ExpandRequestWire = ExpandRequestWire
    { consistency :: !ConsistencyWire
    , object :: !ObjectRefWire
    , permission :: !Text
    , context :: !CaveatContextWire
    , limit :: !Int
    , cursor :: !(Maybe Text)
    }
    deriving stock (Eq, Show, Generic)
    deriving anyclass (FromJSON, ToJSON)

data ExpandNodeWire
    = ExpandSubjectWire !SubjectWire
    | ExpandUsersetWire !ObjectRefWire !Text ![ExpandNodeWire]
    | ExpandCaveatedWire !Text ![ExpandNodeWire]
    deriving stock (Eq, Show, Generic)
    deriving anyclass (FromJSON, ToJSON)

data ExpandStateWire
    = ExpandExhaustedWire
    | ExpandHasMoreWire !Text
    | ExpandTruncatedWire !Text
    deriving stock (Eq, Show, Generic)
    deriving anyclass (FromJSON, ToJSON)

data ExpandTreeWire = ExpandTreeWire
    { root :: !ObjectRefWire
    , permission :: !Text
    , children :: ![ExpandNodeWire]
    , state :: !ExpandStateWire
    }
    deriving stock (Eq, Show, Generic)
    deriving anyclass (FromJSON, ToJSON)

newtype WriteTuplesRequestWire = WriteTuplesRequestWire
    { tuples :: [TupleWire]
    }
    deriving stock (Eq, Show, Generic)
    deriving anyclass (FromJSON, ToJSON)

newtype DeleteTuplesRequestWire = DeleteTuplesRequestWire
    { tuples :: [TupleWire]
    }
    deriving stock (Eq, Show, Generic)
    deriving anyclass (FromJSON, ToJSON)

newtype WriteTuplesResponseWire = WriteTuplesResponseWire
    { token :: Text
    }
    deriving stock (Eq, Show, Generic)
    deriving anyclass (FromJSON, ToJSON)

newtype ErrorWire = ErrorWire
    { error :: Text
    }
    deriving stock (Eq, Show, Generic)
    deriving anyclass (FromJSON, ToJSON)

writeTuplesHandler :: EnServer -> WriteTuplesRequestWire -> Handler WriteTuplesResponseWire
writeTuplesHandler env request = do
    tuples <- traverseOr400 tupleFromWire request.tuples
    token <- liftIO (env.tupleStore.writeTuples tuples)
    pure (tokenToWire token)

deleteTuplesHandler :: EnServer -> DeleteTuplesRequestWire -> Handler WriteTuplesResponseWire
deleteTuplesHandler env request = do
    tuples <- traverseOr400 tupleFromWire request.tuples
    token <- liftIO (env.tupleStore.deleteTuples tuples)
    pure (tokenToWire token)

checkHandler :: EnServer -> CheckRequestWire -> Handler CheckResponseWire
checkHandler env request = do
    consistency <- either400 (consistencyFromWire request.consistency)
    context <- either400 (contextFromWire request.context)
    subject <- either400 (subjectFromWire request.subject)
    object <- either400 (objectRefFromWire request.object)
    decision <-
        liftIO
            ( check
                env.consistencyStore
                env.tupleStore
                env.graph
                consistency
                context
                subject
                (RelationName request.permission)
                object
            )
            >>= eitherEngine
    pure CheckResponseWire{decision = decisionToWire decision}

lookupHandler :: EnServer -> LookupRequestWire -> Handler LookupPageWire
lookupHandler env request = do
    consistency <- either400 (consistencyFromWire request.consistency)
    context <- either400 (contextFromWire request.context)
    subject <- either400 (subjectFromWire request.subject)
    page <-
        liftIO
            ( Lookup.lookup
                env.consistencyStore
                env.tupleStore
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
            >>= eitherEngine
    pure (lookupPageToWire page)

expandHandler :: EnServer -> ExpandRequestWire -> Handler ExpandTreeWire
expandHandler env request = do
    consistency <- either400 (consistencyFromWire request.consistency)
    context <- either400 (contextFromWire request.context)
    object <- either400 (objectRefFromWire request.object)
    tree <-
        liftIO
            ( Expand.expand
                env.consistencyStore
                env.tupleStore
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
            >>= eitherEngine
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

traverseOr400 :: (a -> Either Text b) -> [a] -> Handler [b]
traverseOr400 convert values =
    either400 (traverse convert values)

either400 :: Either Text a -> Handler a
either400 =
    either (throwError . jsonError err400) pure

eitherEngine :: Either EnError a -> Handler a
eitherEngine =
    either (throwError . jsonError err500 . Text.pack . show) pure

jsonError :: ServerError -> Text -> ServerError
jsonError err message =
    err
        { errBody = encode ErrorWire{error = message}
        , errHeaders = [("Content-Type", Text.encodeUtf8 "application/json")]
        }
