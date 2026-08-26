-- | Wire vocabulary shared by two or more en operations, and the domain conversions
-- for it. A type used by more than one vertical slice has no single owning slice, so it
-- lives here: @ObjectRefWire@ and @SubjectWire@ appear in every operation;
-- @ConsistencyWire@ and the caveat types in check/lookup/expand/tuple; @CheckDecisionWire@
-- in both check and lookup.
--
-- Every JSON instance is written by hand so the wire shape is a reviewed artifact rather
-- than a side effect of generic derivation. Both @toJSON@ and @toEncoding@ are defined so
-- field order is fixed, which is what lets the golden tests compare exact bytes.
module En.Servant.Wire
  ( ObjectRefWire (..),
    SubjectWire (..),
    CaveatValueWire (..),
    CaveatPayloadWire (..),
    CaveatContextWire (..),
    ConsistencyWire (..),
    CheckDecisionWire (..),
    CaveatObligationWire (..),
    unknownVariant,
    objectRefToWire,
    objectRefFromWire,
    subjectToWire,
    subjectFromWire,
    consistencyToWire,
    consistencyFromWire,
    valueToWire,
    valueFromWire,
    payloadToWire,
    payloadFromWire,
    contextFromWire,
    decisionToWire,
    obligationToWire,
    positiveLimit,
    nonEmptyRelation,
  )
where

import Data.Aeson
  ( FromJSON (..),
    Object,
    ToJSON (..),
    pairs,
    withObject,
    (.:),
    (.=),
  )
import Data.Aeson qualified as Aeson
import Data.Aeson.Types (Parser)
import Data.Generics.Labels ()
import Data.Map.Strict (Map)
import Data.Text qualified as Text
import En.Check (CaveatObligation (..), CheckDecision (..))
import En.Prelude hiding ((.=))
import En.Revision (Consistency (..), ConsistencyToken (..))
import En.Schema (CaveatName (..), ObjectType (..), RelationName (..))
import En.Tuple
  ( CaveatContext (..),
    CaveatPayload (..),
    CaveatValue (..),
    ObjectRef (..),
    Subject (..),
  )

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
  { objectType :: !Text,
    objectId :: !Text
  }
  deriving stock (Generic, Eq, Show)

instance ToJSON ObjectRefWire where
  toJSON wire = Aeson.object ["objectType" .= (wire ^. #objectType), "objectId" .= (wire ^. #objectId)]
  toEncoding wire = pairs ("objectType" .= (wire ^. #objectType) <> "objectId" .= (wire ^. #objectId))

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
  deriving stock (Generic, Eq, Show)

instance ToJSON SubjectWire where
  toJSON = \case
    SubjectIdWire ref ->
      Aeson.object ["kind" .= ("id" :: Text), "objectType" .= (ref ^. #objectType), "objectId" .= (ref ^. #objectId)]
    SubjectSetWire ref relation ->
      Aeson.object
        [ "kind" .= ("set" :: Text),
          "objectType" .= (ref ^. #objectType),
          "objectId" .= (ref ^. #objectId),
          "relation" .= relation
        ]
    SubjectWildcardWire objectType ->
      Aeson.object ["kind" .= ("wildcard" :: Text), "objectType" .= objectType]
  toEncoding = \case
    SubjectIdWire ref ->
      pairs ("kind" .= ("id" :: Text) <> "objectType" .= (ref ^. #objectType) <> "objectId" .= (ref ^. #objectId))
    SubjectSetWire ref relation ->
      pairs
        ( "kind" .= ("set" :: Text)
            <> "objectType" .= (ref ^. #objectType)
            <> "objectId" .= (ref ^. #objectId)
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
  deriving stock (Generic, Eq, Show)

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
  deriving stock (Generic, Eq, Show)

instance ToJSON CaveatPayloadWire where
  toJSON wire = Aeson.object ["values" .= (wire ^. #values)]
  toEncoding wire = pairs ("values" .= (wire ^. #values))

instance FromJSON CaveatPayloadWire where
  parseJSON = withObject "CaveatPayloadWire" \o -> CaveatPayloadWire <$> o .: "values"

newtype CaveatContextWire = CaveatContextWire
  { values :: Map Text CaveatValueWire
  }
  deriving stock (Generic, Eq, Show)

instance ToJSON CaveatContextWire where
  toJSON wire = Aeson.object ["values" .= (wire ^. #values)]
  toEncoding wire = pairs ("values" .= (wire ^. #values))

instance FromJSON CaveatContextWire where
  parseJSON = withObject "CaveatContextWire" \o -> CaveatContextWire <$> o .: "values"

data ConsistencyWire
  = MinimizeLatencyWire
  | FullyConsistentWire
  | AtLeastAsFreshWire !Text
  | AtExactSnapshotWire !Text
  deriving stock (Generic, Eq, Show)

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

data CheckDecisionWire
  = AllowedWire
  | DeniedWire
  | ConditionalWire ![CaveatObligationWire]
  deriving stock (Generic, Eq, Show)

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
  { caveat :: !Text,
    missingContext :: ![Text]
  }
  deriving stock (Generic, Eq, Show)

instance ToJSON CaveatObligationWire where
  toJSON wire = Aeson.object ["caveat" .= (wire ^. #caveat), "missingContext" .= (wire ^. #missingContext)]
  toEncoding wire = pairs ("caveat" .= (wire ^. #caveat) <> "missingContext" .= (wire ^. #missingContext))

instance FromJSON CaveatObligationWire where
  parseJSON = withObject "CaveatObligationWire" \o ->
    CaveatObligationWire <$> o .: "caveat" <*> o .: "missingContext"

objectRefToWire :: ObjectRef -> ObjectRefWire
objectRefToWire ObjectRef {objectType = ObjectType objectType, objectId} =
  ObjectRefWire {objectType, objectId}

objectRefFromWire :: ObjectRefWire -> Either Text ObjectRef
objectRefFromWire ObjectRefWire {objectType, objectId}
  | Text.null objectType = Left "objectType must not be empty"
  | Text.null objectId = Left "objectId must not be empty"
  | otherwise = Right ObjectRef {objectType = ObjectType objectType, objectId}

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

decisionToWire :: CheckDecision -> CheckDecisionWire
decisionToWire =
  \case
    Allowed -> AllowedWire
    Denied -> DeniedWire
    Conditional obligations -> ConditionalWire (obligationToWire <$> obligations)

obligationToWire :: CaveatObligation -> CaveatObligationWire
obligationToWire CaveatObligation {caveat = CaveatName caveat, missingContext} =
  CaveatObligationWire {caveat, missingContext}

-- | A page limit must be positive. Zero would return an empty page whose cursor equals
-- the caller's own, so a drain loop over it never terminates and never advances.
positiveLimit :: Int -> Either Text Int
positiveLimit limit
  | limit <= 0 = Left "limit must be positive"
  | otherwise = Right limit

nonEmptyRelation :: Text -> Text -> Either Text RelationName
nonEmptyRelation label value
  | Text.null value = Left (label <> " must not be empty")
  | otherwise = Right (RelationName value)
