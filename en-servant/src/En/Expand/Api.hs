{-# LANGUAGE TypeOperators #-}

{- | The expand HTTP slice: the subject tree behind a permission on one object, with the
operator nodes (union / intersection / exclusion) that let an access review tell a
conjunction from a disjunction. The @\/v1@ prefix is factored to the umbrella in
"En.Servant.API".
-}
module En.Expand.Api (
    -- * Routes
    ExpandRoutes (..),
    expandRoutesServer,

    -- * Wire types
    ExpandRequestWire (..),
    ExpandNodeWire (..),
    ExpandStateWire (..),
    ExpandTreeWire (..),

    -- * Handlers
    expandHandler,
) where

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
import Data.Text (Text)
import Effectful qualified
import Effectful.Error.Static (Error)
import GHC.Generics (Generic)
import Servant (Handler, JSON, ReqBody, StdMethod (..), type (:>))
import Servant.API.Generic (type (:-))
import Servant.API.MultiVerb (MultiVerb)
import Servant.Server.Generic (AsServerT)

import En.Effect.ConsistencyStore (ConsistencyStore)
import En.Effect.TupleStore (TupleStore)
import En.Error (EnError)
import En.Expand qualified as Expand
import En.Revision (ConsistencyToken (..))
import En.Schema (CaveatName (..), RelationName (..))
import En.Servant.Response (
    EnResponses,
    EnResult,
    activeSchema,
    enHandler,
    engine,
    orInvalid,
 )
import En.Servant.Seam (ActiveSchema (..), Env (..))
import En.Servant.Wire (
    CaveatContextWire,
    ConsistencyWire,
    ObjectRefWire,
    SubjectWire,
    consistencyFromWire,
    contextFromWire,
    objectRefFromWire,
    objectRefToWire,
    subjectToWire,
    unknownVariant,
 )

-- * Routes

data ExpandRoutes mode = ExpandRoutes
    { expand ::
        mode
            :- "expand"
                :> ReqBody '[JSON] ExpandRequestWire
                :> MultiVerb 'POST '[JSON] (EnResponses "The permission's subject tree" ExpandTreeWire) (EnResult ExpandTreeWire)
    }
    deriving stock (Generic)

expandRoutesServer ::
    (ConsistencyStore Effectful.:> es, TupleStore Effectful.:> es, Error EnError Effectful.:> es) =>
    Env es ->
    ExpandRoutes (AsServerT Handler)
expandRoutesServer env =
    ExpandRoutes{expand = expandHandler env}

-- * Wire types

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

-- * Handlers

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

-- * Conversions

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
