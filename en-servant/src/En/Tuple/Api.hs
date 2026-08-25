{-# LANGUAGE TypeOperators #-}

-- | The tuple-store HTTP slice: writing, deleting, reading, filtered deletion, and the
-- changelog feed. Every operation here acts on the relationship tuples 'En.Tuple.Tuple'
-- names, shares the 'RelationshipFilterWire' vocabulary, and reads or writes the same
-- store, so they form one vertical slice. The URL prefix @\/v1@ is factored to the
-- umbrella in "En.Servant.API"; the routes below are relative to it.
module En.Tuple.Api
  ( -- * Routes
    TupleRoutes (..),
    tupleRoutesServer,

    -- * Wire types
    TupleWire (..),
    TupleCaveatWire (..),
    SubjectRelationFilterWire (..),
    TupleFilterWire (..),
    PreconditionWire (..),
    WriteTuplesRequestWire (..),
    DeleteTuplesRequestWire (..),
    WriteTuplesResponseWire (..),
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

    -- * Handlers
    writeTuplesHandler,
    deleteTuplesHandler,
    readRelationshipsHandler,
    deleteRelationshipsHandler,
    watchHandler,

    -- * Conversions
    tupleToWire,
    tupleFromWire,
    preconditionFromWire,
    relationshipFilterFromWire,
  )
where

import Data.Aeson
  ( FromJSON (..),
    ToJSON (..),
    pairs,
    withObject,
    (.:),
    (.:?),
    (.=),
  )
import Data.Aeson qualified as Aeson
import Data.Int (Int64)
import Data.Maybe (fromMaybe)
import Data.Text (Text)
import Data.Text qualified as Text
import Effectful qualified
import En.Effect.ConsistencyStore (ConsistencyStore, ResolvedConsistency (..), mintToken, resolveConsistency)
import En.Effect.TupleStore
  ( ChangeKind (..),
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
import En.Revision (Consistency (..), ConsistencyToken (..))
import En.Schema (CaveatName (..), ObjectType (..), RelationName (..))
import En.Servant.Response
  ( EnResponses,
    EnResult,
    activeSchema,
    enHandler,
    engine,
    orInvalid,
    traverseOrInvalid,
  )
import En.Servant.Seam (Env (..))
import En.Servant.Wire
  ( CaveatPayloadWire,
    ConsistencyWire,
    ObjectRefWire,
    SubjectWire,
    consistencyFromWire,
    objectRefFromWire,
    objectRefToWire,
    payloadFromWire,
    payloadToWire,
    positiveLimit,
    subjectFromWire,
    subjectToWire,
    unknownVariant,
  )
import En.Tuple (Tuple (..), TupleCaveat (..))
import En.Watch qualified as Watch
import GHC.Generics (Generic)
import Servant (Handler, JSON, ReqBody, StdMethod (..), type (:>))
import Servant.API.Generic (type (:-))
import Servant.API.MultiVerb (MultiVerb)
import Servant.Server.Generic (AsServerT)

-- * Routes

data TupleRoutes mode = TupleRoutes
  { writeTuples ::
      mode
        :- "relationships"
          :> ReqBody '[JSON] WriteTuplesRequestWire
          :> MultiVerb 'POST '[JSON] (EnResponses "Consistency token for the write" WriteTuplesResponseWire) (EnResult WriteTuplesResponseWire),
    deleteTuples ::
      mode
        :- "relationships"
          :> "delete"
          :> ReqBody '[JSON] DeleteTuplesRequestWire
          :> MultiVerb 'POST '[JSON] (EnResponses "Consistency token for the deletion" WriteTuplesResponseWire) (EnResult WriteTuplesResponseWire),
    readRelationships ::
      mode
        :- "relationships"
          :> "query"
          :> ReqBody '[JSON] ReadRelationshipsRequestWire
          :> MultiVerb 'POST '[JSON] (EnResponses "A page of stored relationships" ReadRelationshipsResponseWire) (EnResult ReadRelationshipsResponseWire),
    deleteRelationships ::
      mode
        :- "relationships"
          :> "delete-by-filter"
          :> ReqBody '[JSON] DeleteRelationshipsRequestWire
          :> MultiVerb 'POST '[JSON] (EnResponses "How many relationships the filter matched" DeleteRelationshipsResponseWire) (EnResult DeleteRelationshipsResponseWire),
    watch ::
      mode
        :- "watch"
          :> ReqBody '[JSON] WatchRequestWire
          :> MultiVerb 'POST '[JSON] (EnResponses "A batch of tuple changes, and a cursor to resume from" WatchResponseWire) (EnResult WatchResponseWire)
  }
  deriving stock (Generic)

tupleRoutesServer ::
  (ConsistencyStore Effectful.:> es, TupleStore Effectful.:> es) =>
  Env es ->
  TupleRoutes (AsServerT Handler)
tupleRoutesServer env =
  TupleRoutes
    { writeTuples = writeTuplesHandler env,
      deleteTuples = deleteTuplesHandler env,
      readRelationships = readRelationshipsHandler env,
      deleteRelationships = deleteRelationshipsHandler env,
      watch = watchHandler env
    }

-- * Wire types

data TupleCaveatWire = TupleCaveatWire
  { name :: !Text,
    payload :: !CaveatPayloadWire
  }
  deriving stock (Eq, Show)

instance ToJSON TupleCaveatWire where
  toJSON wire = Aeson.object ["name" .= wire.name, "payload" .= wire.payload]
  toEncoding wire = pairs ("name" .= wire.name <> "payload" .= wire.payload)

instance FromJSON TupleCaveatWire where
  parseJSON = withObject "TupleCaveatWire" \o ->
    TupleCaveatWire <$> o .: "name" <*> o .: "payload"

data TupleWire = TupleWire
  { object :: !ObjectRefWire,
    relation :: !Text,
    subject :: !SubjectWire,
    caveat :: !(Maybe TupleCaveatWire)
  }
  deriving stock (Eq, Show)

instance ToJSON TupleWire where
  toJSON wire =
    Aeson.object
      [ "object" .= wire.object,
        "relation" .= wire.relation,
        "subject" .= wire.subject,
        "caveat" .= wire.caveat
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

-- | How a filter constrains the subject's relation.
--
-- @match@ discriminates. Omitting the whole @subjectRelation@ field means @any@,
-- which is what SpiceDB's unset @optionalRelation@ means. To name one exact grant
-- on a concrete subject, send @{"match":"none"}@ — @any@ would also match a userset
-- over that subject, which is a different grant that can be live at the same time.
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

-- | A filter over live tuples. Every field but @objectType@ is optional; an
-- omitted field matches anything.
data TupleFilterWire = TupleFilterWire
  { objectType :: !Text,
    objectId :: !(Maybe Text),
    relation :: !(Maybe Text),
    subjectType :: !(Maybe Text),
    subjectId :: !(Maybe Text),
    subjectRelation :: !(Maybe SubjectRelationFilterWire)
  }
  deriving stock (Eq, Show)

-- | An absent constraint is an absent key, not a @null@ one: @null@ would read as
-- "the subject relation must be null", which 'NoSubjectRelationWire' already says.
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

-- | A write request: @tuples@ are written, @deletes@ are removed first, and every
-- precondition must hold or the whole request is refused with @412@.
--
-- @deletes@ and @preconditions@ are optional, so a body carrying only @tuples@ —
-- every request written before preconditions existed — decodes and behaves exactly
-- as it did.
data WriteTuplesRequestWire = WriteTuplesRequestWire
  { tuples :: ![TupleWire],
    deletes :: !(Maybe [TupleWire]),
    preconditions :: !(Maybe [PreconditionWire])
  }
  deriving stock (Eq, Show)

-- | Absent optional fields are omitted rather than encoded as @null@, so a request
-- carrying only @tuples@ serializes to exactly the bytes it did before preconditions
-- existed. The golden test in @en-servant/test/Main.hs@ pins that.
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
  { tuples :: ![TupleWire],
    preconditions :: !(Maybe [PreconditionWire])
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

-- | A filter over stored relationships, for reading and for delete-by-filter.
--
-- Every field is optional, but not every combination is legal: the filter must constrain
-- @objectType@ or @subjectType@, @objectId@ requires @objectType@, and @subjectId@ and a
-- @subjectRelation@ other than @any@ require @subjectType@. An illegal filter is a @400@.
-- The rule is not taste — a filter anchored on neither end matches no index and scans the
-- whole table, so accepting one would let any caller hold the store open.
--
-- This is 'TupleFilterWire' with @objectType@ relaxed to optional (so "every grant naming
-- @user:alice@" is expressible) and @caveatName@ added. The two are separate types because
-- a precondition's filter is evaluated inside a write transaction, where an unanchored
-- scan is a lock held over the whole relation, so @objectType@ there is mandatory.
data RelationshipFilterWire = RelationshipFilterWire
  { objectType :: !(Maybe Text),
    objectId :: !(Maybe Text),
    relation :: !(Maybe Text),
    subjectType :: !(Maybe Text),
    subjectId :: !(Maybe Text),
    subjectRelation :: !(Maybe SubjectRelationFilterWire),
    caveatName :: !(Maybe Text)
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
  { consistency :: !ConsistencyWire,
    filter :: !RelationshipFilterWire,
    limit :: !Int,
    cursor :: !(Maybe Text)
  }
  deriving stock (Eq, Show)

instance ToJSON ReadRelationshipsRequestWire where
  toJSON wire =
    Aeson.object
      [ "consistency" .= wire.consistency,
        "filter" .= wire.filter,
        "limit" .= wire.limit,
        "cursor" .= wire.cursor
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

-- | Whether a page of relationships is the last one.
--
-- Two statuses, not the three 'En.Lookup.Api.LookupStateWire' and 'En.Expand.Api.ExpandStateWire'
-- carry: @truncated@ means an evaluation budget ran out mid-page, and a stored-tuple read spends no
-- budget — it walks an index. A store that somehow reported truncation is reported as @hasMore@,
-- which resumes from the same cursor and is therefore correct either way.
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
  { relationships :: ![TupleWire],
    state :: !RelationshipsStateWire,
    checkedAt :: !Text
  }
  deriving stock (Eq, Show)

instance ToJSON ReadRelationshipsResponseWire where
  toJSON wire =
    Aeson.object
      [ "relationships" .= wire.relationships,
        "state" .= wire.state,
        "checkedAt" .= wire.checkedAt
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

-- | A delete-by-filter request. @dryRun@ is mandatory and has no default.
--
-- This is the most destructive operation in the API, and a defaulted flag is one a caller
-- can omit by accident. Requiring it means intent is always stated: a body missing @dryRun@
-- is a @400@, not a deletion.
data DeleteRelationshipsRequestWire = DeleteRelationshipsRequestWire
  { filter :: !RelationshipFilterWire,
    dryRun :: !Bool
  }
  deriving stock (Eq, Show)

instance ToJSON DeleteRelationshipsRequestWire where
  toJSON wire = Aeson.object ["filter" .= wire.filter, "dryRun" .= wire.dryRun]
  toEncoding wire = pairs ("filter" .= wire.filter <> "dryRun" .= wire.dryRun)

instance FromJSON DeleteRelationshipsRequestWire where
  parseJSON = withObject "DeleteRelationshipsRequestWire" \o ->
    DeleteRelationshipsRequestWire <$> o .: "filter" <*> o .: "dryRun"

-- | @count@ is how many grants a real deletion retired, or — for a dry run — how many it
-- would have. @token@ is present exactly when @dryRun@ was false: a dry run writes nothing,
-- so it has no revision to name. A caller that deleted can pass the token straight back as
-- @atLeastAsFresh@ and observe the revocation.
data DeleteRelationshipsResponseWire = DeleteRelationshipsResponseWire
  { dryRun :: !Bool,
    count :: !Int64,
    token :: !(Maybe Text)
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

-- | One poll of the changelog feed.
--
-- Exactly one start position. @cursor@ resumes a subscription; @startToken@ opens one at the
-- snapshot an ordinary consistency token pins ("everything since my write"); both absent
-- starts one at the current head, returning no changes and the cursor to poll with next.
-- Both present is a @400@ — a caller that supplied two start positions does not know where it
-- wants to start, and picking one for it would silently skip or replay history.
--
-- There is no @consistency@ field, and its absence is the contract. A poll's window is fixed
-- by its start position and the store's head; a resuming poll reads the window its cursor
-- names and nothing else. A caller able to ask for a fresher snapshot mid-drain could span two
-- of them and receive a batch with gaps.
--
-- @filter@ scopes the subscription. It is 'RelationshipFilterWire', unchanged, so "watch every
-- grant naming @user:alice@" and "read every grant naming @user:alice@" are the same filter.
data WatchRequestWire = WatchRequestWire
  { cursor :: !(Maybe Text),
    startToken :: !(Maybe Text),
    filter :: !(Maybe RelationshipFilterWire),
    limit :: !Int
  }
  deriving stock (Eq, Show)

instance ToJSON WatchRequestWire where
  toJSON wire =
    Aeson.object
      [ "cursor" .= wire.cursor,
        "startToken" .= wire.startToken,
        "filter" .= wire.filter,
        "limit" .= wire.limit
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

-- | What happened to a tuple: it became live, or it stopped being live.
--
-- A bare string rather than the discriminated object the other sum types carry, because it has
-- no variant-specific fields to discriminate. It is itself the @kind@ discriminator of
-- 'TupleChangeWire'.
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
  { kind :: !ChangeKindWire,
    tuple :: !TupleWire
  }
  deriving stock (Eq, Show)

instance ToJSON TupleChangeWire where
  toJSON wire = Aeson.object ["kind" .= wire.kind, "tuple" .= wire.tuple]
  toEncoding wire = pairs ("kind" .= wire.kind <> "tuple" .= wire.tuple)

instance FromJSON TupleChangeWire where
  parseJSON = withObject "TupleChangeWire" \o ->
    TupleChangeWire <$> o .: "kind" <*> o .: "tuple"

-- | A batch of changes, the cursor that resumes after them, and the snapshot they end at.
--
-- @changes@ carries no order. It is the set difference of the live tuple set across the
-- batch's window: transaction ids are assigned at transaction start and visibility flips at
-- commit, so the store cannot say which of two changes happened first, and pretending
-- otherwise would be a promise it could not keep. Order holds only /between/ batches.
--
-- @cursor@ is always present, including on an empty batch — a caught-up consumer must still be
-- able to poll again. It is opaque: the only thing to do with it is send it back.
--
-- @changes@ can be empty while the feed still has more to give, because a grant written and
-- retired inside one window contributes no event yet still consumes a page. A drain therefore
-- ends when a poll's @cursor@ stops advancing, not at the first empty page.
data WatchResponseWire = WatchResponseWire
  { changes :: ![TupleChangeWire],
    cursor :: !Text,
    checkedAt :: !Text
  }
  deriving stock (Eq, Show)

instance ToJSON WatchResponseWire where
  toJSON wire =
    Aeson.object
      [ "changes" .= wire.changes,
        "cursor" .= wire.cursor,
        "checkedAt" .= wire.checkedAt
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

newtype WriteTuplesResponseWire = WriteTuplesResponseWire
  { token :: Text
  }
  deriving stock (Eq, Show)

instance ToJSON WriteTuplesResponseWire where
  toJSON wire = Aeson.object ["token" .= wire.token]
  toEncoding wire = pairs ("token" .= wire.token)

instance FromJSON WriteTuplesResponseWire where
  parseJSON = withObject "WriteTuplesResponseWire" \o -> WriteTuplesResponseWire <$> o .: "token"

-- * Handlers

writeTuplesHandler :: (TupleStore Effectful.:> es) => Env es -> WriteTuplesRequestWire -> Handler (EnResult WriteTuplesResponseWire)
writeTuplesHandler env request = enHandler do
  active <- activeSchema env
  writes <- traverseOrInvalid tupleFromWire request.tuples
  deletes <- traverseOrInvalid tupleFromWire (fromMaybe [] request.deletes)
  preconditions <- traverseOrInvalid preconditionFromWire (fromMaybe [] request.preconditions)
  token <- engine env active (applyTupleWrites TupleWriteRequest {preconditions, writes, deletes})
  pure (tokenToWire token)

deleteTuplesHandler :: (TupleStore Effectful.:> es) => Env es -> DeleteTuplesRequestWire -> Handler (EnResult WriteTuplesResponseWire)
deleteTuplesHandler env request = enHandler do
  active <- activeSchema env
  deletes <- traverseOrInvalid tupleFromWire request.tuples
  preconditions <- traverseOrInvalid preconditionFromWire (fromMaybe [] request.preconditions)
  token <- engine env active (applyTupleWrites TupleWriteRequest {preconditions, writes = [], deletes})
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
      ResolvedConsistency {revision} <- resolveConsistency consistency
      checkedAt <- mintToken revision
      page <- readRelationships revision relationshipFilter limit (StoreCursor <$> request.cursor)
      pure (checkedAt, page)
  pure (relationshipsPageToWire checkedAt page)

-- | Dry-run and deletion are one endpoint because they must ask the store the same
-- question. Splitting them into @\/count@ and @\/delete@ would invite a caller to count
-- against a snapshot and delete against a later one, and be surprised by the difference.
--
-- The dry run resolves 'FullyConsistent' rather than the caller's consistency: a count read
-- from a stale replica is not a preview of what a delete — which always acts on live state —
-- is about to do.
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
          ResolvedConsistency {revision} <- resolveConsistency FullyConsistent
          countRelationships revision relationshipFilter
      pure DeleteRelationshipsResponseWire {dryRun = True, count, token = Nothing}
    else do
      (count, ConsistencyToken token) <- engine env active (deleteRelationships relationshipFilter)
      pure DeleteRelationshipsResponseWire {dryRun = False, count, token = Just token}

-- | One poll of the changelog feed.
--
-- @limit@ is clamped to 'maxBatchSize' rather than rejected above it, following the deadline's
-- precedent: asking for as much as the server will give is reasonable, and the server decides
-- how much that is. It must still be positive — a zero limit returns an empty page whose
-- cursor equals the caller's own, so a drain loop over it never terminates and never advances.
watchHandler :: Env es -> WatchRequestWire -> Handler (EnResult WatchResponseWire)
watchHandler env request = enHandler do
  active <- activeSchema env
  start <- orInvalid (watchStartFromWire request.cursor request.startToken)
  relationshipFilter <- orInvalid (traverse relationshipFilterFromWire request.filter)
  limit <- orInvalid (positiveLimit request.limit)
  batch <- engine env active (env.watchOperation start relationshipFilter (min env.maxBatchSize limit))
  pure (watchBatchToWire batch)

-- * Conversions

tupleToWire :: Tuple -> TupleWire
tupleToWire Tuple {object, relation = RelationName relation, subject, caveat} =
  TupleWire
    { object = objectRefToWire object,
      relation,
      subject = subjectToWire subject,
      caveat = tupleCaveatToWire <$> caveat
    }

tupleFromWire :: TupleWire -> Either Text Tuple
tupleFromWire TupleWire {object, relation, subject, caveat}
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

-- | An empty string is rejected rather than treated as an absent constraint: a
-- filter whose @objectId@ is @""@ matches nothing, and silently accepting it would
-- make a must-exist precondition fail for a reason the caller cannot see.
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

-- | Convert and then validate: a filter that decodes but does not anchor is still a
-- client fault, and 'validateRelationshipFilter' owns the grammar. The two steps are one
-- function so no handler can perform the first and forget the second.
--
-- As in 'tupleFilterFromWire', an empty string is rejected rather than read as an absent
-- constraint: @objectId: ""@ matches nothing, and silently widening it to "any object" would
-- turn a narrow read into a table scan, or a narrow delete into a mass revocation.
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

relationshipsPageToWire :: ConsistencyToken -> TuplePage -> ReadRelationshipsResponseWire
relationshipsPageToWire (ConsistencyToken checkedAt) TuplePage {rows, state} =
  ReadRelationshipsResponseWire
    { relationships = tupleToWire . (.tuple) <$> rows,
      state = relationshipsStateToWire state,
      checkedAt
    }

-- | Exactly one start position, or a client fault naming which rule was broken.
--
-- An empty string is rejected rather than read as an absent field, as everywhere else in this
-- module: @cursor: ""@ is a cursor this store never issued, and silently starting the feed
-- from now in its place would tell a resuming consumer it was caught up while a window's worth
-- of revocations went unread.
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
watchBatchToWire Watch.WatchBatch {changes, cursor, checkedAt = ConsistencyToken checkedAt} =
  WatchResponseWire {changes = tupleChangeToWire <$> changes, cursor, checkedAt}

tupleChangeToWire :: TupleChange -> TupleChangeWire
tupleChangeToWire TupleChange {kind, tuple} =
  TupleChangeWire {kind = changeKindToWire kind, tuple = tupleToWire tuple}

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
tupleCaveatToWire TupleCaveat {name = CaveatName name, payload} =
  TupleCaveatWire {name, payload = payloadToWire payload}

tupleCaveatFromWire :: TupleCaveatWire -> Either Text TupleCaveat
tupleCaveatFromWire TupleCaveatWire {name, payload}
  | Text.null name = Left "caveat name must not be empty"
  | otherwise = TupleCaveat (CaveatName name) <$> payloadFromWire payload

tokenToWire :: ConsistencyToken -> WriteTuplesResponseWire
tokenToWire (ConsistencyToken token) =
  WriteTuplesResponseWire {token}
