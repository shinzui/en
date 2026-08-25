{-# LANGUAGE TypeOperators #-}

-- | The lookup HTTP slice: "which objects may this subject reach?" and its dual "who can
-- reach this object?". Both are cursored, deadline-bounded traversals over the same graph.
-- The @\/v1@ prefix is factored to the umbrella in "En.Servant.API".
module En.Lookup.Api
  ( -- * Routes
    LookupRoutes (..),
    lookupRoutesServer,

    -- * Wire types
    LookupRequestWire (..),
    LookupObjectWire (..),
    LookupStateWire (..),
    LookupPageWire (..),
    LookupSubjectsRequestWire (..),
    LookupSubjectWire (..),
    LookupSubjectsStateWire (..),
    LookupSubjectsPageWire (..),

    -- * Handlers
    lookupHandler,
    lookupSubjectsHandler,
  )
where

import Control.Monad.IO.Class (liftIO)
import Control.Monad.Trans.Class (lift)
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
import Data.Maybe (fromMaybe)
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Word (Word64)
import Effectful (Eff, IOE)
import Effectful qualified
import En.Lookup qualified as Lookup
import En.LookupSubjects qualified as LookupSubjects
import En.Revision (ConsistencyToken (..))
import En.Schema (ObjectType (..), RelationName (..))
import En.Servant.Problem (ProblemJSON)
import En.Servant.Response
  ( EnResponses,
    EnResult,
    activeSchema,
    enHandler,
    engine,
    orInvalid,
  )
import En.Servant.Seam (ActiveSchema (..), Env (..))
import En.Servant.Wire
  ( CaveatContextWire,
    CheckDecisionWire,
    ConsistencyWire,
    ObjectRefWire,
    SubjectWire,
    consistencyFromWire,
    contextFromWire,
    decisionToWire,
    nonEmptyRelation,
    objectRefFromWire,
    objectRefToWire,
    positiveLimit,
    subjectFromWire,
    subjectToWire,
    unknownVariant,
  )
import GHC.Clock (getMonotonicTimeNSec)
import GHC.Generics (Generic)
import Servant (Handler, JSON, ReqBody, StdMethod (..), type (:>))
import Servant.API.Generic (type (:-))
import Servant.API.MultiVerb (MultiVerb)
import Servant.Server.Generic (AsServerT)

-- * Routes

data LookupRoutes mode = LookupRoutes
  { lookup ::
      mode
        :- "lookup"
          :> ReqBody '[JSON] LookupRequestWire
          :> MultiVerb 'POST '[JSON, ProblemJSON] (EnResponses "A page of authorized objects" LookupPageWire) (EnResult LookupPageWire),
    lookupSubjects ::
      mode
        :- "lookup-subjects"
          :> ReqBody '[JSON] LookupSubjectsRequestWire
          :> MultiVerb 'POST '[JSON, ProblemJSON] (EnResponses "A page of authorized subjects" LookupSubjectsPageWire) (EnResult LookupSubjectsPageWire)
  }
  deriving stock (Generic)

lookupRoutesServer ::
  (IOE Effectful.:> es) =>
  Env es ->
  LookupRoutes (AsServerT Handler)
lookupRoutesServer env =
  LookupRoutes
    { lookup = lookupHandler env,
      lookupSubjects = lookupSubjectsHandler env
    }

-- * Wire types

data LookupRequestWire = LookupRequestWire
  { consistency :: !ConsistencyWire,
    subject :: !SubjectWire,
    permission :: !Text,
    objectType :: !Text,
    context :: !CaveatContextWire,
    limit :: !Int,
    cursor :: !(Maybe Text),
    deadlineMillis :: !(Maybe Int)
  }
  deriving stock (Eq, Show)

instance ToJSON LookupRequestWire where
  toJSON wire =
    Aeson.object
      [ "consistency" .= wire.consistency,
        "subject" .= wire.subject,
        "permission" .= wire.permission,
        "objectType" .= wire.objectType,
        "context" .= wire.context,
        "limit" .= wire.limit,
        "cursor" .= wire.cursor,
        "deadlineMillis" .= wire.deadlineMillis
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
  { object :: !ObjectRefWire,
    decision :: !CheckDecisionWire
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

-- | A page of authorized objects, and the snapshot the lookup reads at.
--
-- Every page of one traversal carries the same @checkedAt@: the cursor pins the
-- snapshot, and a continuation reads at the revision its cursor's validated token
-- names.
data LookupPageWire = LookupPageWire
  { objects :: ![LookupObjectWire],
    state :: !LookupStateWire,
    checkedAt :: !Text
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

-- | "Who has access to this object?"
--
-- @subjectType@ names one object type and is required, which keeps the traversal bounded
-- and the answer homogeneous. @deadlineMillis@ is the live time budget, handled exactly as
-- @\/v1\/lookup@ handles it: omitted means the server default, and a value above the
-- server's ceiling is clamped rather than rejected.
data LookupSubjectsRequestWire = LookupSubjectsRequestWire
  { consistency :: !ConsistencyWire,
    object :: !ObjectRefWire,
    permission :: !Text,
    subjectType :: !Text,
    context :: !CaveatContextWire,
    limit :: !Int,
    cursor :: !(Maybe Text),
    deadlineMillis :: !(Maybe Int)
  }
  deriving stock (Eq, Show)

instance ToJSON LookupSubjectsRequestWire where
  toJSON wire =
    Aeson.object
      [ "consistency" .= wire.consistency,
        "object" .= wire.object,
        "permission" .= wire.permission,
        "subjectType" .= wire.subjectType,
        "context" .= wire.context,
        "limit" .= wire.limit,
        "cursor" .= wire.cursor,
        "deadlineMillis" .= wire.deadlineMillis
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

-- | One subject holding the permission, and on what terms.
--
-- A wildcard grant arrives here as @{"kind": "wildcard", "objectType": "user"}@ — the
-- 'En.Servant.Wire.SubjectWildcardWire' constructor 'En.Servant.Wire.SubjectWire' already has —
-- so it is distinguishable from a concrete subject without a new discriminator. It is never
-- expanded into concrete subjects: the set of users is not en's data.
data LookupSubjectWire = LookupSubjectWire
  { subject :: !SubjectWire,
    decision :: !CheckDecisionWire
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

-- | A page of authorized subjects, and the snapshot the lookup reads at.
--
-- Every page of one traversal carries the same @checkedAt@: the cursor pins the snapshot,
-- and a continuation reads at the revision its cursor's validated token names.
data LookupSubjectsPageWire = LookupSubjectsPageWire
  { subjects :: ![LookupSubjectWire],
    state :: !LookupSubjectsStateWire,
    checkedAt :: !Text
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

-- * Handlers

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
            { subject,
              permission = RelationName request.permission,
              objectType = ObjectType request.objectType,
              context,
              limit = Lookup.LookupLimit request.limit,
              cursor = Lookup.LookupCursor <$> request.cursor
            }
      )
  pure (lookupPageToWire page)

-- | "Who can view this?" — the flat, cursored subject set.
--
-- Unlike @\/v1\/lookup@, this validates @limit@. A zero limit returns an empty page whose
-- cursor equals the caller's own, so a drain loop over it never terminates and never
-- advances; the same reason 'En.Servant.Wire.positiveLimit' guards the relationship read.
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
            { object,
              permission,
              subjectType,
              context,
              limit,
              cursor = LookupSubjects.LookupSubjectsCursor <$> request.cursor
            }
      )
  pure (lookupSubjectsPageToWire page)

-- | The time budget for one lookup, measured on the monotonic clock.
--
-- The server owns the ceiling. An unbounded client-supplied budget is a hostage problem:
-- @deadlineMillis: 86400000@ would pin a worker for a day. A request above
-- 'deadlineMaxMillis' is clamped down to it rather than rejected, so a client asking for
-- more time than it can have still gets an answer.
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

-- * Conversions

nonEmptyObjectType :: Text -> Text -> Either Text ObjectType
nonEmptyObjectType label value
  | Text.null value = Left (label <> " must not be empty")
  | otherwise = Right (ObjectType value)

lookupPageToWire :: Lookup.LookupPage -> LookupPageWire
lookupPageToWire Lookup.LookupPage {objects, state, checkedAt = ConsistencyToken checkedAt} =
  LookupPageWire
    { objects = lookupObjectToWire <$> objects,
      state = lookupStateToWire state,
      checkedAt
    }

lookupObjectToWire :: Lookup.LookupObject -> LookupObjectWire
lookupObjectToWire Lookup.LookupObject {object, decision} =
  LookupObjectWire {object = objectRefToWire object, decision = decisionToWire decision}

lookupStateToWire :: Lookup.LookupState -> LookupStateWire
lookupStateToWire =
  \case
    Lookup.LookupExhausted -> LookupExhaustedWire
    Lookup.LookupHasMore (Lookup.LookupCursor cursor) -> LookupHasMoreWire cursor
    Lookup.LookupTruncated (Lookup.LookupCursor cursor) -> LookupTruncatedWire cursor

lookupSubjectsPageToWire :: LookupSubjects.LookupSubjectsPage -> LookupSubjectsPageWire
lookupSubjectsPageToWire LookupSubjects.LookupSubjectsPage {subjects, state, checkedAt = ConsistencyToken checkedAt} =
  LookupSubjectsPageWire
    { subjects = lookupSubjectToWire <$> subjects,
      state = lookupSubjectsStateToWire state,
      checkedAt
    }

lookupSubjectToWire :: LookupSubjects.LookupSubject -> LookupSubjectWire
lookupSubjectToWire LookupSubjects.LookupSubject {subject, decision} =
  LookupSubjectWire {subject = subjectToWire subject, decision = decisionToWire decision}

lookupSubjectsStateToWire :: LookupSubjects.LookupSubjectsState -> LookupSubjectsStateWire
lookupSubjectsStateToWire =
  \case
    LookupSubjects.SubjectsExhausted -> SubjectsExhaustedWire
    LookupSubjects.SubjectsHasMore (LookupSubjects.LookupSubjectsCursor cursor) -> SubjectsHasMoreWire cursor
    LookupSubjects.SubjectsTruncated (LookupSubjects.LookupSubjectsCursor cursor) -> SubjectsTruncatedWire cursor
